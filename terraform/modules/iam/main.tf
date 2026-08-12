resource "google_service_account" "fetch_runner" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-fetch-runner"
  display_name = "Runs the monthly NYC TLC fetch Cloud Function"
}

resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-sched-invoker"
  display_name = "Cloud Scheduler identity used to invoke the fetch function"
}

resource "google_service_account" "eventarc_trigger" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-eventarc-trg"
  display_name = "Eventarc trigger identity, GCS finalize -> Dataproc submitter"
}

resource "google_service_account" "dataproc_submitter" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-dp-submitter"
  display_name = "Submits a Dataproc Serverless batch for each new raw file"
}

resource "google_service_account" "dataproc_runtime" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-dp-runtime"
  display_name = "Runtime identity for the PySpark Iceberg load job"
}

# --- fetch-runner: write-only to the raw bucket -----------------------------
resource "google_storage_bucket_iam_member" "fetch_runner_raw_write" {
  bucket = var.raw_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.fetch_runner.email}"
}

# --- dataproc-runtime: read raw + code, admin on its own staging area ------
resource "google_storage_bucket_iam_member" "dataproc_runtime_raw_read" {
  bucket = var.raw_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.dataproc_runtime.email}"
}

resource "google_storage_bucket_iam_member" "dataproc_runtime_code_read" {
  bucket = var.code_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.dataproc_runtime.email}"
}

resource "google_storage_bucket_iam_member" "dataproc_runtime_staging_admin" {
  bucket = var.staging_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataproc_runtime.email}"
}

# --- dataproc-submitter: project-scoped batch submission --------------------
# Dataproc batches have no finer-grained resource IAM than project level.
resource "google_project_iam_member" "dataproc_submitter_editor" {
  project = var.project_id
  role    = "roles/dataproc.editor"
  member  = "serviceAccount:${google_service_account.dataproc_submitter.email}"
}

# Submitting a batch that *runs as* dataproc-runtime requires actAs on it.
resource "google_service_account_iam_member" "submitter_acts_as_runtime" {
  service_account_id = google_service_account.dataproc_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.dataproc_submitter.email}"
}

# --- eventarc-trigger: receive GCS events ------------------------------------
resource "google_project_iam_member" "eventarc_trigger_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.eventarc_trigger.email}"
}

# GCS's own service agent must be able to publish to Pub/Sub, or GCS -> GCS
# Eventarc triggers never fire in the first place. Easy to miss because
# nothing in this module "owns" that identity — it's GCP-managed.
data "google_storage_project_service_account" "gcs_sa" {
  project = var.project_id
}

resource "google_project_iam_member" "gcs_sa_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}
