locals {
  apis = [
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
    "cloudscheduler.googleapis.com",
    "dataproc.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "compute.googleapis.com",
    "pubsub.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# Dataproc Serverless just needs a subnet with Private Google Access on. The
# default subnet in this project already has it — no dedicated network.
data "google_compute_subnetwork" "default" {
  name    = "default"
  region  = var.region
  project = var.project_id

  depends_on = [google_project_service.apis]
}

module "storage" {
  source = "../../modules/storage"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix

  depends_on = [google_project_service.apis]
}

module "iam" {
  source = "../../modules/iam"

  project_id          = var.project_id
  name_prefix         = var.name_prefix
  raw_bucket_name     = module.storage.raw_bucket_name
  code_bucket_name    = module.storage.code_bucket_name
  staging_bucket_name = module.storage.staging_bucket_name
}

module "bigquery" {
  source = "../../modules/bigquery"

  project_id             = var.project_id
  region                 = var.region
  dataset_id             = var.dataset_id
  dataproc_runtime_email = module.iam.dataproc_runtime_email
}

module "compute" {
  source = "../../modules/compute"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix

  raw_bucket_name     = module.storage.raw_bucket_name
  code_bucket_name    = module.storage.code_bucket_name
  staging_bucket_name = module.storage.staging_bucket_name

  dataset_id = module.bigquery.dataset_id
  table_id   = var.table_id

  fetch_runner_email       = module.iam.fetch_runner_email
  scheduler_invoker_email  = module.iam.scheduler_invoker_email
  eventarc_trigger_email   = module.iam.eventarc_trigger_email
  dataproc_submitter_email = module.iam.dataproc_submitter_email
  dataproc_runtime_email   = module.iam.dataproc_runtime_email

  subnetwork_self_link = data.google_compute_subnetwork.default.self_link

  fetch_source_dir     = "${path.module}/../../../services/fetch"
  submitter_source_dir = "${path.module}/../../../services/dataproc_submitter"
  pyspark_script_path  = "${path.module}/../../../spark_jobs/process_to_bigquery.py"
}
