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
  description = "BigQuery dataset id for the Iceberg table"
  type        = string
  default     = "nyc_taxi_tf"
}
