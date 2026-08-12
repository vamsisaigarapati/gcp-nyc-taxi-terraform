# Landing zone for untouched NYC TLC parquet files. Multi-region US to match
# the CloudFront source's spread and keep egress cheap regardless of which
# region ends up reading it.
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-${var.name_prefix}-raw"
  project                     = var.project_id
  location                    = "US"
  uniform_bucket_level_access = true
  force_destroy               = false

  lifecycle_rule {
    condition {
      age = 60
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
}

# Iceberg table data + metadata files, read by both the Spark writer and
# BigQuery (via the BigLake connection) at query time.
resource "google_storage_bucket" "warehouse" {
  name                        = "${var.project_id}-${var.name_prefix}-warehouse"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
}

# Cloud Function source zips + the PySpark script/jars referenced by the
# Dataproc Serverless batch. Versioned implicitly via content-hashed object
# names rather than bucket versioning.
resource "google_storage_bucket" "code" {
  name                        = "${var.project_id}-${var.name_prefix}-code"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
}

# Dataproc Serverless working/staging area. Short-lived by design, so
# force_destroy + an aggressive lifecycle rule are appropriate here (unlike
# the other buckets).
resource "google_storage_bucket" "dataproc_staging" {
  name                        = "${var.project_id}-${var.name_prefix}-dataproc-staging"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}
