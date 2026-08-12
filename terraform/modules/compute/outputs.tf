output "fetch_function_uri" {
  value = google_cloudfunctions2_function.fetch.service_config[0].uri
}

output "submitter_function_uri" {
  value = google_cloudfunctions2_function.dataproc_submitter.service_config[0].uri
}
