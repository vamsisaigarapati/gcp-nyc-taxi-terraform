# NYC Taxi Pipeline — Terraform

Monthly ingestion of NYC TLC yellow-taxi parquet files into an Iceberg table
on GCS, queryable from BigQuery via BigLake. The infrastructure is fully
provisioned with Terraform; application code deploys through the same CI
pipeline that applies it.

Project: `nyc-taxi-terraform` · Region: `us-central1`

## Architecture

```
                    ┌─────────────────┐
                    │  Cloud Scheduler │  monthly cron (OIDC token)
                    └────────┬─────────┘
                             │ HTTPS POST
                             v
                 ┌───────────────────────┐
                 │ Cloud Function: fetch  │  pulls last month's parquet
                 └───────────┬────────────┘  from the public NYC TLC CDN
                             │ writes
                             v
                    ┌──────────────────┐
                    │  GCS raw bucket   │  landing zone, untouched parquet
                    └────────┬──────────┘
                             │ object.finalize event
                             v
                    ┌──────────────────┐
                    │     Eventarc      │  GCS -> Pub/Sub -> trigger
                    └────────┬──────────┘
                             │ invokes
                             v
             ┌────────────────────────────────┐
             │ Cloud Function: dataproc-submit │  parses the event,
             └───────────────┬─────────────────┘  submits a Dataproc batch
                              │ Dataproc Batches API
                              v
                ┌──────────────────────────┐
                │ Dataproc Serverless batch │  runs process_to_iceberg.py
                └─────────────┬─────────────┘
                               │ writes Iceberg data + metadata
                               v
                  ┌─────────────────────────┐
                  │ GCS warehouse bucket     │  Iceberg table storage
                  │ (BigLake Metastore       │
                  │  catalog on top of it)   │
                  └────────────┬─────────────┘
                               │ read through the BigLake connection
                               v
                     ┌───────────────────┐
                     │     BigQuery       │  nyc_taxi_tf.yellow_tripdata
                     └───────────────────┘
```

Every arrow above is a service-account-scoped call — see [IAM design](#iam-design-service-accounts)
below for exactly which identity makes which hop.

### Why Cloud Functions Gen2 instead of plain Cloud Run + Docker

The existing hand-built prototype (`gcp_iceberg_project`, not this repo) is
written as `functions_framework` Cloud Functions. Reusing that code as
`google_cloudfunctions2_function` resources meant no Dockerfile, no
Artifact Registry pipeline — Terraform zips the source, uploads it to GCS,
and Cloud Build (managed by the Functions Gen2 build path) produces the
image. Functions Gen2 *is* Cloud Run underneath, so this doesn't lose
anything the original architecture wanted — it just avoids owning a
container pipeline for two small handlers.

### Why Cloud Functions instead of a static `google_dataproc_batch`

Eventarc has no native Dataproc target — GCS events can only land on Cloud
Run, Cloud Functions, GKE, or Workflows. And a Terraform-declared
`google_dataproc_batch` resource only submits *once*, at `terraform apply`
time; it doesn't repeat itself every time a new monthly file lands. So
Terraform's job here is to own the *infrastructure* (the receiver
function, its service account, the code/staging buckets) — the receiver
calls the Dataproc Batches API at runtime, once per new file, exactly the
pattern the original prototype's `trigger_spark_job` function already
proved out.

### Why the PySpark job re-registers itself with BigQuery on every run

BigLake Iceberg tables are exposed to BigQuery as external tables pointing
at a specific Iceberg `metadata.json` location, and that location changes
on every write. A Terraform-declared `google_bigquery_table` would be
static and go stale after the first load. So `process_to_iceberg.py` ends
each run with a `CREATE OR REPLACE EXTERNAL TABLE ... WITH CONNECTION ...
OPTIONS (table_format = 'ICEBERG', storage_uri = '<latest metadata>')`
call via the BigQuery REST API — the same "runtime owns what changes at
runtime" split as the Dataproc submission above.

## IAM design (service accounts)

Nothing in this stack runs as the default Compute Engine service account.
Five purpose-built service accounts, each scoped to only what that one hop
needs:

| Service account | Attached to | Roles |
|---|---|---|
| `fetch-runner` | `fetch` Cloud Function | `storage.objectCreator` on the raw bucket only |
| `scheduler-invoker` | Cloud Scheduler job | `run.invoker` on the `fetch` function's service only |
| `eventarc-trigger` | Eventarc trigger identity | `eventarc.eventReceiver` (project-scoped — no finer grain exists) + `run.invoker` on the `dataproc-submit` function |
| `dataproc-submitter` | `dataproc-submit` Cloud Function | `dataproc.editor` (project-scoped) + `iam.serviceAccountUser` on `dataproc-runtime` (needed to submit a batch that runs *as* another SA) |
| `dataproc-runtime` | The Spark batch itself | `storage.objectViewer` on raw + code buckets, `storage.objectAdmin` on warehouse + staging buckets, `bigquery.dataEditor` scoped to the dataset, `bigquery.jobUser` + `biglake.admin` (project-scoped) |

Two more grants that are easy to miss because neither identity is one we
created:

- **GCS's own service agent** (`service-{project_number}@gs-project-accounts.iam.gserviceaccount.com`)
  needs `pubsub.publisher` at project level, or GCS→Eventarc triggers never
  fire — GCS delivers finalize events by publishing to a Pub/Sub topic
  Eventarc manages internally.
- **The BigLake connection's auto-created service account** (output of
  `google_bigquery_connection`) needs `storage.objectViewer` on the raw and
  warehouse buckets, since BigQuery reads the underlying Iceberg files
  through that identity at query time — separate from `dataproc-runtime`,
  which is the *writer*.

## Terraform design

```
terraform/
  modules/
    storage/    raw, warehouse, code, and Dataproc-staging GCS buckets
    iam/        the 5 service accounts + every binding above
    bigquery/   dataset, BigLake connection, dataset/bucket IAM grants
    compute/    the 2 Cloud Functions, Cloud Scheduler job, Eventarc trigger
  envs/
    dev/        wires the 4 modules together; the only root module applied
```

Design choices, and why:

- **One module per GCP surface area, not per pipeline stage.** `storage`
  owns every bucket regardless of which stage writes to it; `iam` owns
  every service account regardless of which stage runs as it. This keeps
  IAM auditable in one place (`terraform plan` against just the `iam`
  module shows every grant in the stack) instead of scattered across
  stage-shaped modules.
- **Dependency order matches the data flow**: `storage` has no
  dependencies → `iam` needs bucket names (for bucket-scoped bindings) →
  `bigquery` needs bucket names + the `dataproc-runtime` email (for
  dataset-scoped bindings) → `compute` needs everything (function env vars
  reference bucket names, the BigLake connection ID, and every service
  account email). `envs/dev/main.tf` wires them in that order via module
  outputs, so Terraform's own dependency graph enforces it — no manual
  `depends_on` chains beyond the couple of explicit ones needed for IAM
  bindings that must exist before a resource that relies on them (e.g. the
  Scheduler job depends on its `run.invoker` binding existing first).
- **`envs/dev` as the only state-carrying root module.** The four modules
  under `modules/` are pure building blocks with no backend config of
  their own; only `envs/dev` has a `backend.tf`. Adding a second
  environment later means a new `envs/<name>/` directory reusing the same
  modules with a different `terraform.tfvars` and state prefix — no
  changes to the modules themselves.
- **Naming is entirely `${project_id}-${name_prefix}-*`.** Every bucket,
  service account, function, and job name derives from the two variables
  in `terraform.tfvars` (`project_id`, `name_prefix`). This is what makes
  this a "fresh, separate stack" — running it against a project that
  already has a hand-built version of this pipeline (as the original
  prototype project does) can't collide with it, since GCS bucket names
  are globally unique and every name here is prefixed by the project ID.
- **`archive_file` + `google_storage_bucket_object` drive function
  deploys.** The `compute` module zips `services/fetch/` and
  `services/dataproc_submitter/` locally, uploads each zip under a
  content-hashed object name, and points the Cloud Function at that
  object. A code change produces a new hash, a new object, and a new
  function revision — `terraform apply` alone is a complete code deploy,
  which is what lets the CI pipeline in `.github/workflows/terraform.yml`
  be a single `terraform apply` rather than a separate build/push step.
- **APIs are enabled from the root module** (`envs/dev/main.tf`,
  `google_project_service` over a list), not from inside each module —
  API enablement is project-wide, so it belongs at the level that owns
  the project, and every module that needs an API `depends_on` that one
  resource.

## Bootstrap: resources created outside Terraform, and why

A handful of resources have to exist *before* `terraform init` can work at
all — Terraform can't create the backend it stores its own state in, or
the identity it authenticates as. These were created once, by hand, via
`gcloud` (full commands in `docs/BOOTSTRAP.md`):

| Resource | Why it can't be Terraform-managed |
|---|---|
| GCP project `nyc-taxi-terraform` + billing link | Terraform needs a project to point its provider at before it can do anything |
| `cloudscheduler`, `cloudresourcemanager`, `sts`, `compute` APIs | `cloudresourcemanager`/`sts` are needed for Terraform itself and for Workload Identity Federation token exchange; the rest gate the very first `google_project_service` apply |
| GCS bucket `nyc-taxi-terraform-tf-state` (versioned) | This *is* the Terraform backend — a backend can't provision itself |
| Service account `ci-deployer` + 11 project-level admin roles | The identity GitHub Actions authenticates as; it needs enough IAM to create everything the main config manages (functions, buckets, service accounts, IAM bindings, BigQuery, Eventarc, Scheduler) |
| Workload Identity Federation pool + OIDC provider, scoped to `vamsisaigarapati`'s GitHub account | Lets GitHub Actions impersonate `ci-deployer` via short-lived OIDC tokens — no static JSON service-account key ever leaves GCP |
| `ci-deployer` ← `roles/iam.workloadIdentityUser` binding, scoped to *this exact repo* | Without this, any repo under the account (not just this one) could mint tokens against the pool |

Everything below that line — every bucket, service account, function,
dataset, scheduler job, and trigger the pipeline actually runs on — is
Terraform-managed, defined in `terraform/`.

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
docs/
  BOOTSTRAP.md           # exact one-time gcloud commands from the table above
```

## CI/CD

`.github/workflows/terraform.yml`: a `lint` job (flake8 over `services/`
and `spark_jobs/`) gates two others — `plan` on pull requests (fmt check,
validate, plan, authenticated via WIF, no static credentials) and `apply`
on pushes to `main`. Since the Cloud Functions deploy is just another
Terraform resource (see [Terraform design](#terraform-design) above),
`terraform apply` is the entire deploy — infra and app code land together,
in one plan.

## Running locally

```
cd terraform/envs/dev
terraform init
terraform plan
terraform apply
```
