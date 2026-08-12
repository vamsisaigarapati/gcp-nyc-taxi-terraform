# The dataset is Terraform-owned. The table inside it isn't (see
# spark_jobs/process_to_bigquery.py) — its schema is set by the Spark job on
# first write via createDisposition=CREATE_IF_NEEDED, since the NYC TLC
# source schema has changed across years and hardcoding it here would drift.
resource "google_bigquery_dataset" "nyc_taxi" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.region
}

resource "google_bigquery_dataset_iam_member" "dataproc_runtime_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.nyc_taxi.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${var.dataproc_runtime_email}"
}

# roles/bigquery.jobUser has no resource below project level to scope to —
# it's what lets dataproc-runtime run the load job the Spark BigQuery
# connector issues under the hood.
resource "google_project_iam_member" "dataproc_runtime_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.dataproc_runtime_email}"
}
