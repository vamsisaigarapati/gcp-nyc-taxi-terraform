output "dataset_id" {
  value = google_bigquery_dataset.nyc_taxi.dataset_id
}

output "connection_id" {
  value = google_bigquery_connection.biglake.connection_id
}

output "connection_name" {
  value = google_bigquery_connection.biglake.name
}
