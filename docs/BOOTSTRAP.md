# Bootstrap

These steps run once, by hand, before `terraform init` can work in
`terraform/envs/dev`. They can't be done by Terraform itself — the state
bucket and the identity Terraform/CI authenticates as have to exist first.

Project: `nyc-taxi-terraform` (project number `787209049782`), billing
account `018F7B-A75945-53FA4D`.

## 1. Enable the APIs bootstrap itself needs

```
gcloud services enable cloudscheduler.googleapis.com cloudresourcemanager.googleapis.com sts.googleapis.com \
  --project=nyc-taxi-terraform
```

## 2. Terraform state bucket

```
gcloud storage buckets create gs://nyc-taxi-terraform-tf-state \
  --project=nyc-taxi-terraform --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://nyc-taxi-terraform-tf-state --versioning
```

## 3. `ci-deployer` service account

```
gcloud iam service-accounts create ci-deployer \
  --project=nyc-taxi-terraform \
  --display-name="GitHub Actions Terraform deployer"
```

## 4. Roles it needs to manage everything the main Terraform config creates

```
for ROLE in roles/cloudfunctions.admin roles/run.admin roles/iam.serviceAccountUser \
            roles/iam.serviceAccountAdmin roles/resourcemanager.projectIamAdmin \
            roles/storage.admin roles/dataproc.admin roles/bigquery.admin \
            roles/eventarc.admin roles/cloudscheduler.admin roles/serviceusage.serviceUsageAdmin; do
  gcloud projects add-iam-policy-binding nyc-taxi-terraform \
    --member="serviceAccount:ci-deployer@nyc-taxi-terraform.iam.gserviceaccount.com" \
    --role="$ROLE" --condition=None
done
```

## 5. Workload Identity Federation pool + provider

Scoped to `vamsisaigarapati`'s GitHub repos via an attribute condition, so
no other GitHub account can mint tokens against this pool.

```
gcloud iam workload-identity-pools create github-actions-pool \
  --project=nyc-taxi-terraform --location=global --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc github-actions-provider \
  --project=nyc-taxi-terraform --location=global \
  --workload-identity-pool=github-actions-pool \
  --display-name="GitHub Actions Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'vamsisaigarapati'" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

## 6. Let only this repo impersonate `ci-deployer`

```
gcloud iam service-accounts add-iam-policy-binding \
  ci-deployer@nyc-taxi-terraform.iam.gserviceaccount.com \
  --project=nyc-taxi-terraform --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/787209049782/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/vamsisaigarapati/gcp-nyc-taxi-terraform"
```
