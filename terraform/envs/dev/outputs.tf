output "raw_bucket_name" {
  value = module.storage.raw_bucket_name
}

output "warehouse_bucket_name" {
  value = module.storage.warehouse_bucket_name
}

output "code_bucket_name" {
  value = module.storage.code_bucket_name
}

output "bigquery_dataset" {
  value = module.bigquery.dataset_id
}

output "fetch_function_uri" {
  value = module.compute.fetch_function_uri
}

output "submitter_function_uri" {
  value = module.compute.submitter_function_uri
}

output "blms_catalog" {
  value = module.compute.blms_catalog
}
