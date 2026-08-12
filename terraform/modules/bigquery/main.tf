resource "google_bigquery_dataset" "nyc_taxi" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.region
}

# BigLake connection: lets BigQuery read the Iceberg table the Spark job
# writes directly to GCS, through a GCP-managed identity rather than a user
# credential.
resource "google_bigquery_connection" "biglake" {
  project       = var.project_id
  connection_id = "${var.name_prefix}-biglake-connection"
  location      = var.region
  cloud_resource {}
}

# The connection's auto-created SA only ever needs to *read* the underlying
# files at query time — the Spark job (dataproc-runtime) is the writer.
resource "google_storage_bucket_iam_member" "biglake_sa_raw_read" {
  bucket = var.raw_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.biglake.cloud_resource[0].service_account_id}"
}

resource "google_storage_bucket_iam_member" "biglake_sa_warehouse_read" {
  bucket = var.warehouse_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.biglake.cloud_resource[0].service_account_id}"
}

# dataproc-runtime is the actual Iceberg writer, so unlike the BigLake
# connection SA above it needs write access to the warehouse bucket, not
# just read.
resource "google_storage_bucket_iam_member" "dataproc_runtime_warehouse_write" {
  bucket = var.warehouse_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.dataproc_runtime_email}"
}

resource "google_bigquery_dataset_iam_member" "dataproc_runtime_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.nyc_taxi.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${var.dataproc_runtime_email}"
}

# roles/bigquery.jobUser and roles/biglake.admin have no resource below
# project level to scope to.
resource "google_project_iam_member" "dataproc_runtime_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.dataproc_runtime_email}"
}

resource "google_project_iam_member" "dataproc_runtime_biglake_admin" {
  project = var.project_id
  role    = "roles/biglake.admin"
  member  = "serviceAccount:${var.dataproc_runtime_email}"
}
