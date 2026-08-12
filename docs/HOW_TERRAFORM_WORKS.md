# How this Terraform config actually works

Written for someone who hasn't used Terraform before. It walks through what
`terraform apply` does in this repo, step by step, using the `storage`
module as the running example.

## First: there's nothing magic about the filename `main.tf`

Terraform reads **every** `.tf` file in a directory and merges them into one
configuration — the filenames are just a human convention, not a rule
Terraform enforces. In this repo:

- `main.tf` — where the actual resources (buckets, service accounts,
  functions...) get declared
- `variables.tf` — declares the *inputs* that directory accepts
- `outputs.tf` — declares the *values* that directory exposes to whoever
  calls it
- `providers.tf` / `backend.tf` / `versions.tf` — only in `envs/dev/`,
  explained below

Nothing stops you from putting everything in one file called `whatever.tf`.
The convention exists purely so a human (or a new Claude session) can guess
where to look.

## Two different kinds of directory in this repo

```
terraform/
  modules/storage/    <- a "child module": a reusable building block
  envs/dev/            <- the "root module": the only thing you actually run
```

**`modules/storage/`** (and `iam/`, `bigquery/`, `compute/`) are not
connected to any GCP project, region, or backend on their own. They're
libraries — a `main.tf` full of resource definitions that reference
`var.something`, with no idea what project or values those variables will
actually hold. Running `terraform apply` *inside* `modules/storage/`
directly would fail: there's no `backend.tf`, no `provider` block, no
values supplied for its variables.

**`envs/dev/`** is the only directory with a `backend.tf` (points at the
real state bucket) and a `providers.tf` (points at the real GCP project).
It's the *only* directory you ever run `terraform init/plan/apply` in. Its
job is to pick concrete values (from `terraform.tfvars`) and wire the four
modules together in the right order. That split is also why adding a
second environment later is cheap: you'd add `envs/prod/` with its own
`backend.tf` + `terraform.tfvars`, calling the *same* four modules with
different values — no changes to `modules/` at all.

## What a `module` block does

In `envs/dev/main.tf` you'll see blocks like this:

```hcl
module "storage" {
  source = "../../modules/storage"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix
}
```

Read this as: *"Go load every `.tf` file in `../../modules/storage`, treat
it as a self-contained unit, and hand it these three values for its
`project_id`/`region`/`name_prefix` variables."* Terraform evaluates that
module's `main.tf` using those values, and whatever that module's
`outputs.tf` declares becomes available back in `envs/dev` as
`module.storage.<output_name>`.

This is why `compute` (and `iam`, `bigquery`) show up as blocks inside
`envs/dev/main.tf` and nowhere else: `envs/dev/main.tf` is the one place in
the repo that actually decides *what gets built* — it calls each module
once, in the order the pipeline needs, passing the previous module's
outputs into the next module's inputs.

## Walking one module end to end: `storage`

**1. The module declares what it needs** (`modules/storage/variables.tf`):

```hcl
variable "project_id"  { type = string }
variable "region"      { type = string }
variable "name_prefix" { type = string }
```

**2. The module declares what it builds** (`modules/storage/main.tf`), using
those variables:

```hcl
resource "google_storage_bucket" "raw" {
  name = "${var.project_id}-${var.name_prefix}-raw"
  ...
}
```

**3. The module declares what it exposes** (`modules/storage/outputs.tf`):

```hcl
output "raw_bucket_name" {
  value = google_storage_bucket.raw.name
}
```

**4. The root module calls it** (`envs/dev/main.tf`), supplying real
values that ultimately come from `terraform.tfvars`
(`project_id = "nyc-taxi-terraform"`, `name_prefix = "nyc-taxi"`):

```hcl
module "storage" {
  source      = "../../modules/storage"
  project_id  = var.project_id   # "nyc-taxi-terraform"
  region      = var.region
  name_prefix = var.name_prefix  # "nyc-taxi"
}
```

**5. The result flows to other modules.** A few lines later, in the same
file:

```hcl
module "iam" {
  source          = "../../modules/iam"
  raw_bucket_name = module.storage.raw_bucket_name  # <- from step 3/4
  ...
}
```

`module.storage.raw_bucket_name` resolves to `"nyc-taxi-terraform-nyc-taxi-raw"`
and gets handed to the `iam` module as *its* `raw_bucket_name` input, which
`modules/iam/main.tf` then uses directly:

```hcl
resource "google_storage_bucket_iam_member" "fetch_runner_raw_write" {
  bucket = var.raw_bucket_name   # the exact string from step 3
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.fetch_runner.email}"
}
```

That's the entire mechanism, repeated: `storage` → `iam`/`bigquery` →
`compute`. Terraform doesn't care about the order the `module` blocks are
*written* in — it builds a dependency graph from these output→input
references (`module.storage.raw_bucket_name` used inside `module "iam"`
means iam depends on storage) and applies things in the order that graph
requires, in parallel wherever nothing depends on anything else.

## What happens when you run `terraform apply` in `envs/dev`

1. **Init** (`terraform init`) reads `backend.tf`, connects to the
   `nyc-taxi-terraform-tf-state` GCS bucket, and downloads the `google`,
   `google-beta`, and `archive` provider plugins pinned in
   `.terraform.lock.hcl`.
2. **Plan** reads every `.tf` file in `envs/dev`, resolves every `module`
   block the way described above, and — walking the whole dependency graph
   across all four modules — works out exactly which real GCP API calls
   would be needed to make reality match the configuration. Nothing is
   changed yet; this is a dry run.
3. **Apply** executes that plan for real, resource by resource, in
   dependency order: buckets first (nothing depends on anything), then the
   service accounts and their bucket-scoped IAM bindings (which need the
   bucket names), then the BigQuery dataset and its grants (needs the
   `dataproc-runtime` service account to exist), then the Cloud Functions,
   Scheduler job, and Eventarc trigger (needs all of the above — env vars
   reference bucket names and service account emails, and the IAM
   `run.invoker` bindings have to exist before the Scheduler job and
   Eventarc trigger that depend on them).
4. Every resource created — across all four modules — lands in **one**
   state file in the state bucket, addressed by its full module path, e.g.
   `module.storage.google_storage_bucket.raw` or
   `module.iam.google_service_account.dataproc_runtime`. That's how a later
   `terraform plan` knows what already exists without re-reading all of GCP.
