# Landing zone for untouched NYC TLC parquet files. Regional, matching
# var.region — not multi-region "US" — because the Eventarc trigger that
# watches this bucket for new objects must be created in exactly the same
# location as the bucket itself (GCP rejects "US" + "us-central1" as a
# mismatch), and the trigger's destination (the submitter Cloud Function)
# is regional in us-central1 anyway.
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-${var.name_prefix}-raw"
  project                     = var.project_id
  location                    = var.region
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

# Cloud Function source zips + the PySpark script referenced by the
# Dataproc Serverless batch. Versioned implicitly via content-hashed object
# names rather than bucket versioning.
resource "google_storage_bucket" "code" {
  name                        = "${var.project_id}-${var.name_prefix}-code"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
}

# Dual-purpose scratch space: Dataproc Serverless's own working/staging
# area, and the temporary GCS bucket the Spark BigQuery connector stages
# rows through before loading them into BigQuery. Short-lived by design, so
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
