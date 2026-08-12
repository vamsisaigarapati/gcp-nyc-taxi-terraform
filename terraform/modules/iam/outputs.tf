output "fetch_runner_email" {
  value = google_service_account.fetch_runner.email
}

output "scheduler_invoker_email" {
  value = google_service_account.scheduler_invoker.email
}

output "eventarc_trigger_email" {
  value = google_service_account.eventarc_trigger.email
}

output "dataproc_submitter_email" {
  value = google_service_account.dataproc_submitter.email
}

output "dataproc_runtime_email" {
  value = google_service_account.dataproc_runtime.email
}

output "dataproc_runtime_name" {
  value = google_service_account.dataproc_runtime.name
}
