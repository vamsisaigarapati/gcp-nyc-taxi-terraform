variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Region for regional buckets"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for naming resources in this stack"
  type        = string
}
