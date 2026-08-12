output "raw_bucket_name" {
  value = google_storage_bucket.raw.name
}

output "warehouse_bucket_name" {
  value = google_storage_bucket.warehouse.name
}

output "code_bucket_name" {
  value = google_storage_bucket.code.name
}

output "staging_bucket_name" {
  value = google_storage_bucket.dataproc_staging.name
}
