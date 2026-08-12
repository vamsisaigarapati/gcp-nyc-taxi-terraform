variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "raw_bucket_name" {
  type = string
}

variable "code_bucket_name" {
  type = string
}

variable "staging_bucket_name" {
  type = string
}

variable "dataset_id" {
  type = string
}

variable "table_id" {
  type = string
}

variable "fetch_runner_email" {
  type = string
}

variable "scheduler_invoker_email" {
  type = string
}

variable "eventarc_trigger_email" {
  type = string
}

variable "dataproc_submitter_email" {
  type = string
}

variable "dataproc_runtime_email" {
  type = string
}

variable "subnetwork_self_link" {
  type = string
}

variable "fetch_source_dir" {
  type = string
}

variable "submitter_source_dir" {
  type = string
}

variable "pyspark_script_path" {
  type = string
}
