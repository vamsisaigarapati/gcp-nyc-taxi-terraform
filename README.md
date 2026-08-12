# NYC Taxi Pipeline — Terraform

Monthly NYC TLC yellow-taxi parquet ingestion into an Iceberg table, queryable
from BigQuery via BigLake. Fully provisioned with Terraform; app code deploys
through the same CI pipeline.

```
Cloud Scheduler --> Cloud Function (fetch) --> GCS raw bucket
                                                     |
                                              Eventarc (GCS finalize)
                                                     v
                                   Cloud Function (dataproc-submit)
                                                     |
                                     Dataproc Serverless batch (PySpark)
                                                     |
                                        Iceberg table via BigLake Metastore
                                                     |
                                              BigQuery (queryable)
```

## Why Cloud Functions instead of a static `google_dataproc_batch`

Eventarc has no native Dataproc target, and a Terraform-declared
`google_dataproc_batch` only runs once, at `terraform apply` time — it
doesn't repeat itself for each new monthly file. So Terraform owns the
*infrastructure* (the receiver function, its service account, the code
bucket); the receiver calls the Dataproc Batches API at runtime, once per
new file, same as `dataproc_submitter/main.py`.

## Layout

```
terraform/
  modules/{storage,iam,bigquery,compute}/
  envs/dev/
services/
  fetch/                 # Cloud Function: pulls the monthly parquet file
  dataproc_submitter/    # Cloud Function: Eventarc target, submits the Spark batch
spark_jobs/
  process_to_iceberg.py  # Runs inside the Dataproc Serverless batch
```

## Service accounts

Five purpose-built service accounts, each scoped to only what it needs —
see the IAM module and the plan doc for the full table. Nothing in this
stack runs as the default Compute Engine service account.

## Bootstrapping

The Terraform state bucket, the `ci-deployer` service account, and its
Workload Identity Federation binding to this repo are created once, by
hand, before `terraform init` can run here (see `docs/BOOTSTRAP.md`).

## Running locally

```
cd terraform/envs/dev
terraform init
terraform plan
terraform apply
```
