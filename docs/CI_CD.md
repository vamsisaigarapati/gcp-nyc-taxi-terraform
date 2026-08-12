# What the GitHub Actions pipeline actually does

One workflow, `.github/workflows/terraform.yml`, three jobs. This walks
through what each one does, where code physically goes, and why
authentication uses an OIDC token instead of a stored credential.

## The three jobs

```
pull_request  ──▶  lint  ──▶  plan     (dry run only, posts no changes to GCP)
push to main  ──▶  lint  ──▶  apply    (actually creates/updates resources)
```

**`lint`** — checks out the repo, installs `flake8`, and runs it over
`services/` and `spark_jobs/`. Pure static analysis, no GCP credentials
involved. Catches syntax errors and obvious style issues in the Python
before anything talks to Google Cloud.

**`plan`** (pull requests only) — authenticates to GCP (see OIDC below),
runs `terraform init` + `terraform validate` + `terraform plan` inside
`terraform/envs/dev`. `terraform plan` is read-only: it diffs the config
against real GCP state and prints what *would* change, without changing
anything. This is what a reviewer looks at before approving a PR.

**`apply`** (pushes to `main` only) — same authentication, then
`terraform init` + `terraform apply -auto-approve`. This is the only job
that actually creates or modifies real resources.

## Where the code actually goes

There's no separate "build and push a Docker image" step in this
pipeline, and that's deliberate (see the README's "Terraform design"
section for why Cloud Functions Gen2 was chosen). Here's the real path a
code change takes:

1. You edit `services/fetch/main.py` (or `dataproc_submitter/main.py`, or
   `spark_jobs/process_to_bigquery.py`) and push to `main`.
2. The `apply` job checks out the repo — so the runner now has your
   changed file on local disk, same as it is in the repo.
3. `terraform apply` runs. Inside `terraform/modules/compute/main.tf`, an
   `archive_file` data source zips up `services/fetch/` (and separately
   `services/dataproc_submitter/`) **from that checked-out copy**, and a
   `google_storage_bucket_object` resource uploads the zip to the
   `code` GCS bucket under a name derived from the zip's content hash.
4. The `google_cloudfunctions2_function` resource points at that GCS
   object. Since the hash changed, Terraform sees the function's source
   changed and triggers Cloud Functions' own build (Cloud Build, managed
   automatically by the Functions Gen2 deploy path) and a new revision
   rollout.
5. `spark_jobs/process_to_bigquery.py` is uploaded the same way, to a
   fixed path in the `code` bucket — the Dataproc Serverless batch reads it
   straight from GCS by URI at submit time, no build step needed for it at
   all.

So "the CI pipeline makes code ready," concretely: **`terraform apply` is
the deploy.** A merged PR that only touched `services/fetch/main.py` still
runs the full `terraform apply`, but since nothing else in the config
changed, Terraform's diff is just "this one function's source object is
different" — everything else is a no-op.

## Why OIDC instead of a stored service-account key

The old way to let GitHub Actions touch GCP was: create a service account,
download its JSON private key, paste it into a GitHub Actions secret. That
key is a permanent bearer credential — anyone who gets it (a leaked log, a
compromised dependency in the workflow, a misconfigured secret) can use it
from anywhere, forever, until someone notices and manually revokes it.

This repo uses **Workload Identity Federation (WIF)** instead, which is
why the workflow has `id-token: write` in its `permissions` block and an
`auth` step instead of a secret. The chain, end to end:

1. **GitHub mints a short-lived OIDC token.** When the `google-github-actions/auth@v2`
   step runs, GitHub's own OIDC issuer (`token.actions.githubusercontent.com`)
   issues a signed JWT scoped to *this specific workflow run* — it carries
   claims like which repo, which branch, and who triggered it. It's valid
   for minutes and generated fresh every run; there's nothing long-lived to
   leak.
2. **GCP checks that token against the WIF provider's trust rule.** The
   `github-actions-provider` created during bootstrap (`docs/BOOTSTRAP.md`,
   step 5) is configured to trust tokens from that GitHub issuer, but *only*
   if the token's `repository_owner` claim equals `vamsisaigarapati` (the
   `--attribute-condition` flag at creation time). A token from someone
   else's fork or a different account would be rejected here.
3. **GCP's Security Token Service (STS) exchanges the GitHub token for a
   GCP one.** This is why `sts.googleapis.com` had to be enabled during
   bootstrap — it's the service that does this exchange. The resulting GCP
   token is itself short-lived (expires with the job).
4. **That GCP token is allowed to impersonate `ci-deployer`, and only for
   this repo.** Bootstrap step 6 granted `roles/iam.workloadIdentityUser`
   on the `ci-deployer` service account, but scoped via a `principalSet`
   to `attribute.repository/vamsisaigarapati/gcp-nyc-taxi-terraform`
   specifically — not "any repo `vamsisaigarapati` owns." A workflow in a
   different repo of yours could authenticate via the same pool but
   couldn't impersonate this service account.
5. **Terraform runs as `ci-deployer`**, using that short-lived, scoped
   token, for the remainder of the job. When the job ends, the token is
   simply no longer valid — there's no credential to revoke afterward
   because nothing durable was ever issued.

Net effect: no secret lives in GitHub at all, nothing to rotate, and a
leaked workflow log can't be replayed later since the token it might
contain is already expired by the time anyone would use it.
