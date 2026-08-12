variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix used for naming every resource in this stack"
  type        = string
  default     = "nyc-taxi"
}

variable "dataset_id" {
  description = "BigQuery dataset id for the taxi table"
  type        = string
  default     = "nyc_taxi_tf"
}

variable "table_id" {
  description = "BigQuery table id the Spark job writes to (created by the job itself, not Terraform)"
  type        = string
  default     = "yellow_tripdata"
}
