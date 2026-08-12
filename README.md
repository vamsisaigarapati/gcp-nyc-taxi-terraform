# NYC Taxi Pipeline — Terraform

Monthly ingestion of NYC TLC yellow-taxi parquet files into a native
BigQuery table. The infrastructure is fully provisioned with Terraform;
application code deploys through the same CI pipeline that applies it.

Project: `nyc-taxi-terraform` · Region: `us-central1`

New to this repo? Two companion docs go deeper than this README:
- [`docs/CI_CD.md`](docs/CI_CD.md) — exactly what the GitHub Actions
  pipeline does, where code physically goes, and why it authenticates with
  an OIDC token instead of a stored key.
- [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md) — the one-time `gcloud` commands
  that had to run before Terraform could take over.

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
             │ Cloud Function: dataproc-submit │  parses the event, loads
             └───────────────┬─────────────────┘  batch_config.json, submits
                              │ Dataproc Batches API   a Dataproc batch
                              v
                ┌──────────────────────────┐
                │ Dataproc Serverless batch │  runs process_to_bigquery.py
                └─────────────┬─────────────┘  (Spark BigQuery connector)
                               │ stages rows via a temp GCS bucket,
                               │ then loads them into BigQuery
                               v
                     ┌───────────────────┐
                     │     BigQuery       │  nyc_taxi_tf.yellow_tripdata
                     │  (native table)     │  (native table)
                     └───────────────────┘
```

Every arrow above is a service-account-scoped call — see
[IAM design](#iam-design-service-accounts) below for exactly which identity
makes which hop.

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
calls the Dataproc Batches API at runtime, once per new file.

### Why the Dataproc batch's compute shape lives in its own file

`dataproc_submitter/main.py` only handles *event parsing and submission* —
which file landed, is it a parquet, build a batch ID, call the API. The
actual shape of the job it submits (Dataproc runtime version, executor
count, executor cores/memory) lives in
[`services/dataproc_submitter/batch_config.json`](services/dataproc_submitter/batch_config.json),
loaded at runtime. Two reasons:

- **Tuning the job shouldn't mean editing code.** Bumping executor count
  is a data change to a JSON file, not a code change to the function that
  parses GCS events.
- **Dataproc Serverless silently picks a small default shape if you don't
  set anything** (autoscaling driver + 2 executors on default machine
  types). For a monthly batch of ~50–60MB parquet files that default is
  probably fine, but leaving it implicit means nobody reviewing this repo
  can see what it actually runs on. `batch_config.json` makes that an
  explicit, version-controlled choice instead of an invisible default.

### Direct write to BigQuery — no Iceberg/BigLake hop

`process_to_bigquery.py` writes straight into a native BigQuery table
using the Spark BigQuery connector (`format("bigquery")`), staging rows
through the same GCS bucket Dataproc Serverless already uses for its own
staging (`temporaryGcsBucket`). An earlier version of this pipeline routed
through an Iceberg table on GCS with a BigLake Metastore catalog and a
BigQuery external-table pointer — that added a warehouse bucket, a
BigLake connection, extra IAM grants, and a REST-catalog sync step, for a
capability (Iceberg time travel, engine-agnostic table format) this
project doesn't currently need. Writing directly is simpler end to end.

The dataset itself is Terraform-managed; the *table* inside it isn't —
see the comment in `spark_jobs/process_to_bigquery.py` for why
(`createDisposition=CREATE_IF_NEEDED` lets the job infer schema, since the
NYC TLC source schema has changed across years).

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
| `dataproc-runtime` | The Spark batch itself | `storage.objectViewer` on raw + code buckets, `storage.objectAdmin` on the staging bucket (Dataproc's own staging *and* the BigQuery connector's temp bucket), `bigquery.dataEditor` scoped to the dataset, `bigquery.jobUser` (project-scoped — runs the load job the connector issues), `dataproc.worker` (project-scoped — lets the Dataproc agent inside the batch register itself and report status; without it, batches fail within seconds, before Spark even starts) |

One more grant that's easy to miss because the identity isn't one we
created: **GCS's own service agent**
(`service-{project_number}@gs-project-accounts.iam.gserviceaccount.com`)
needs `pubsub.publisher` at project level, or GCS→Eventarc triggers never
fire — GCS delivers finalize events by publishing to a Pub/Sub topic
Eventarc manages internally.

## Terraform design

```
terraform/
  modules/
    storage/    raw, code, and Dataproc-staging GCS buckets
    iam/        the 5 service accounts + every binding above
    bigquery/   dataset + dataset/project IAM grants
    compute/    the 2 Cloud Functions, Cloud Scheduler job, Eventarc trigger
  envs/
    dev/        wires the 4 modules together; the only root module applied
```

Design choices, and why:

- **One module per GCP surface area, not per pipeline stage.** `storage`
  owns every bucket regardless of which stage writes to it; `iam` owns
  every service account regardless of which stage runs as it. This keeps
  IAM auditable in one place — `terraform plan` against just the `iam`
  module shows every grant in the stack.
- **Dependency order matches the data flow**: `storage` has no
  dependencies → `iam` needs bucket names (bucket-scoped bindings) →
  `bigquery` needs the `dataproc-runtime` email (dataset-scoped bindings)
  → `compute` needs everything (function env vars reference bucket names,
  the dataset/table id, and every service account email). `envs/dev/main.tf`
  wires them in that order via module outputs, so Terraform's own
  dependency graph enforces it.
- **`envs/dev` as the only state-carrying root module.** The four modules
  under `modules/` are pure building blocks with no backend config of
  their own; only `envs/dev` has a `backend.tf`. A second environment
  later means a new `envs/<name>/` directory reusing the same modules with
  different `terraform.tfvars` — no changes to the modules themselves.
- **Naming is entirely `${project_id}-${name_prefix}-*`.** Every bucket,
  service account, function, and job name derives from the two variables
  in `terraform.tfvars`. This is what makes this a "fresh, separate stack"
  — it can't collide with a hand-built version of this pipeline in the
  same or a different project, since GCS bucket names are globally unique
  and every name here is prefixed by the project ID.
- **`archive_file` + `google_storage_bucket_object` drive function
  deploys.** The `compute` module zips `services/fetch/` and
  `services/dataproc_submitter/` locally, uploads each zip under a
  content-hashed object name, and points the Cloud Function at that
  object. A code change produces a new hash, a new object, and a new
  function revision — `terraform apply` alone is a complete code deploy.
  See `docs/CI_CD.md` for the full path a code change takes through CI.
- **APIs are enabled from the root module** (`envs/dev/main.tf`,
  `google_project_service` over a list), not from inside each module —
  API enablement is project-wide, so it belongs at the level that owns the
  project.

## Bootstrap: resources created outside Terraform, and why

A handful of resources have to exist *before* `terraform init` can work at
all — Terraform can't create the backend it stores its own state in, or
the identity it authenticates as. These were created once, by hand, via
`gcloud` (full commands in [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md)):

| Resource | Why it can't be Terraform-managed |
|---|---|
| GCP project `nyc-taxi-terraform` + billing link | Terraform needs a project to point its provider at before it can do anything |
| `cloudscheduler`, `cloudresourcemanager`, `sts`, `compute` APIs | `cloudresourcemanager`/`sts` are needed for Terraform itself and for Workload Identity Federation token exchange; the rest gate the very first `google_project_service` apply |
| GCS bucket `nyc-taxi-terraform-tf-state` (versioned) | This *is* the Terraform backend — a backend can't provision itself |
| Service account `ci-deployer` + 11 project-level admin roles | The identity GitHub Actions authenticates as; it needs enough IAM to create everything the main config manages (functions, buckets, service accounts, IAM bindings, BigQuery, Eventarc, Scheduler) |
| Workload Identity Federation pool + OIDC provider, scoped to `vamsisaigarapati`'s GitHub account | Lets GitHub Actions impersonate `ci-deployer` via short-lived OIDC tokens — no static JSON service-account key ever leaves GCP. Full explanation in `docs/CI_CD.md`. |
| `ci-deployer` ← `roles/iam.workloadIdentityUser` binding, scoped to *this exact repo* | Without this, any repo under the account (not just this one) could mint tokens against the pool |

Everything below that line — every bucket, service account, function,
dataset, scheduler job, and trigger the pipeline actually runs on — is
Terraform-managed, defined in `terraform/`.

## Issues hit standing this up, and how they were diagnosed

None of these were guessed — each was traced to a root cause via live GCP
state (build logs, IAM policy dumps, Dataproc batch `stateMessage`, direct
authenticated requests) before being fixed.

1. **Cloud Function builds failed with "missing permission on the build
   service account."** Root cause: an org policy,
   `iam.automaticIamGrantsForDefaultServiceAccounts`, enforced at the
   `vamcsaig-org` level, disables GCP's usual behavior of auto-granting
   roles to default/service-agent identities the first time you use a
   service. This surfaced three times in a row, once per identity that
   normally gets an automatic grant: the Cloud Build service account
   needed `artifactregistry.writer` (to push the built image) and
   `logging.logWriter` (to write build logs); the Cloud Functions service
   agent needed `artifactregistry.reader` (to read the auto-created
   `gcf-artifacts` repo); the default Compute Engine service account
   (which Cloud Functions Gen2 actually runs the buildpacks build as)
   needed `storage.objectViewer` (to read the uploaded source zip). Fixed
   with one-off `gcloud projects add-iam-policy-binding` grants — these
   are Google-internal build-plumbing identities, not part of this
   pipeline's own IAM design (see [IAM design](#iam-design-service-accounts)
   above for the identities that *are*).
2. **`Error creating Trigger: ... Bucket location "us" does not match
   trigger location "us-central1"`.** The raw bucket was multi-region
   `"US"`; Eventarc requires a GCS-triggered trigger's location to exactly
   match its bucket's location, and the trigger here is necessarily
   regional (its destination, the submitter Cloud Function, lives in
   `us-central1`). Fixed by making the raw bucket regional too — see the
   comment on `google_storage_bucket.raw` in
   `terraform/modules/storage/main.tf`.
3. **Dataproc batches failed within ~5 seconds, before Spark ever
   started.** The batch's own `stateMessage` named the exact cause:
   `dataproc-runtime` was missing `roles/dataproc.worker`. This is a
   distinct requirement from *data* access (storage/BigQuery roles it
   already had) — any custom service account used as a Dataproc batch's
   execution identity needs it so the Dataproc agent inside the batch's
   environment can register itself and report status back to the control
   plane at all. Added to `terraform/modules/iam/main.tf`.
4. **A Cloud Scheduler-triggered run looked like an infrastructure
   failure (502) but wasn't.** Invoking the `fetch` function directly
   (bypassing Scheduler, with a properly scoped identity token) showed it
   ran successfully and returned its own, deliberate `502` for "this
   month's file isn't published on the NYC TLC CDN yet." The bug: `502`
   is also Cloud Run's own status code for "your container crashed,"
   so the two failure modes were indistinguishable from the outside.
   Changed to `404` in `services/fetch/main.py`, and separately fixed the
   underlying cause — NYC TLC's publishing lag was longer than assumed, so
   `fetch` now requests the same month two years back rather than N months
   before "today," which is always safely past the lag.

## Layout

```
terraform/
  modules/{storage,iam,bigquery,compute}/
  envs/dev/
services/
  fetch/                 # Cloud Function: pulls the monthly parquet file
  dataproc_submitter/    # Cloud Function: Eventarc target, submits the Spark batch
    batch_config.json    # compute shape for the Dataproc batch, kept out of the code
spark_jobs/
  process_to_bigquery.py # Runs inside the Dataproc Serverless batch
docs/
  BOOTSTRAP.md           # exact one-time gcloud commands from the table above
  CI_CD.md                # what GitHub Actions does + the OIDC auth chain
```

## CI/CD

`.github/workflows/terraform.yml`: a `lint` job (flake8 over `services/`
and `spark_jobs/`) gates two others — `plan` on pull requests (fmt check,
validate, plan, authenticated via WIF, no static credentials) and `apply`
on pushes to `main`. Full breakdown, including the OIDC auth chain, in
[`docs/CI_CD.md`](docs/CI_CD.md).

## Running locally

```
cd terraform/envs/dev
terraform init
terraform plan
terraform apply
```
