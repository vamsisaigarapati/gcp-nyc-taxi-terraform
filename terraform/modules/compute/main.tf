# --- fetch function -----------------------------------------------------

data "archive_file" "fetch_zip" {
  type        = "zip"
  source_dir  = var.fetch_source_dir
  output_path = "${path.module}/.build/fetch.zip"
}

resource "google_storage_bucket_object" "fetch_zip" {
  name   = "functions/fetch-${data.archive_file.fetch_zip.output_md5}.zip"
  bucket = var.code_bucket_name
  source = data.archive_file.fetch_zip.output_path
}

resource "google_cloudfunctions2_function" "fetch" {
  name     = "${var.name_prefix}-fetch"
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "fetch_raw_data"
    source {
      storage_source {
        bucket = var.code_bucket_name
        object = google_storage_bucket_object.fetch_zip.name
      }
    }
  }

  service_config {
    available_memory               = "512Mi"
    timeout_seconds                = 300
    max_instance_count             = 3
    ingress_settings               = "ALLOW_ALL"
    all_traffic_on_latest_revision = true
    service_account_email          = var.fetch_runner_email

    environment_variables = {
      BUCKET_NAME = var.raw_bucket_name
    }
  }
}

# Only the Scheduler's own identity may invoke this function — no
# allUsers/allAuthenticatedUsers binding, so the default IAM check applies.
resource "google_cloud_run_service_iam_member" "fetch_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.fetch.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.scheduler_invoker_email}"
}

resource "google_cloud_scheduler_job" "fetch_monthly" {
  name      = "${var.name_prefix}-monthly-fetch"
  project   = var.project_id
  region    = var.region
  schedule  = "0 6 3 * *"
  time_zone = "Etc/UTC"

  http_target {
    uri         = google_cloudfunctions2_function.fetch.service_config[0].uri
    http_method = "POST"

    oidc_token {
      service_account_email = var.scheduler_invoker_email
      audience              = google_cloudfunctions2_function.fetch.service_config[0].uri
    }
  }

  depends_on = [google_cloud_run_service_iam_member.fetch_invoker]
}

# --- dataproc submitter function -----------------------------------------

data "archive_file" "submitter_zip" {
  type        = "zip"
  source_dir  = var.submitter_source_dir
  output_path = "${path.module}/.build/submitter.zip"
}

resource "google_storage_bucket_object" "submitter_zip" {
  name   = "functions/submitter-${data.archive_file.submitter_zip.output_md5}.zip"
  bucket = var.code_bucket_name
  source = data.archive_file.submitter_zip.output_path
}

resource "google_storage_bucket_object" "pyspark_script" {
  name   = "spark_jobs/process_to_bigquery.py"
  bucket = var.code_bucket_name
  source = var.pyspark_script_path
}

resource "google_cloudfunctions2_function" "dataproc_submitter" {
  name     = "${var.name_prefix}-dataproc-submit"
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "trigger_spark_job"
    source {
      storage_source {
        bucket = var.code_bucket_name
        object = google_storage_bucket_object.submitter_zip.name
      }
    }
  }

  service_config {
    available_memory      = "256Mi"
    timeout_seconds       = 60
    max_instance_count    = 3
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = var.dataproc_submitter_email

    environment_variables = {
      PROJECT_ID               = var.project_id
      REGION                   = var.region
      RAW_BUCKET               = var.raw_bucket_name
      DATAPROC_SUBNETWORK      = var.subnetwork_self_link
      DATAPROC_SERVICE_ACCOUNT = var.dataproc_runtime_email
      PYSPARK_FILE_URI         = "gs://${var.code_bucket_name}/${google_storage_bucket_object.pyspark_script.name}"
      STAGING_BUCKET           = var.staging_bucket_name
      BQ_TABLE                 = "${var.project_id}.${var.dataset_id}.${var.table_id}"
    }
  }
}

# Only the Eventarc trigger's identity may invoke this function.
resource "google_cloud_run_service_iam_member" "submitter_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.dataproc_submitter.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.eventarc_trigger_email}"
}

resource "google_eventarc_trigger" "raw_file_trigger" {
  name     = "${var.name_prefix}-raw-file-trigger"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = var.raw_bucket_name
  }

  destination {
    cloud_run_service {
      service = google_cloudfunctions2_function.dataproc_submitter.name
      region  = var.region
    }
  }

  service_account = var.eventarc_trigger_email

  depends_on = [google_cloud_run_service_iam_member.submitter_invoker]
}
