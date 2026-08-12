# This bucket is created by hand in Phase 0 (bootstrap), before this backend
# can be initialized — a Terraform-managed backend can't bootstrap itself.
terraform {
  backend "gcs" {
    bucket = "nyc-taxi-terraform-tf-state"
    prefix = "nyc-taxi-pipeline/dev"
  }
}
