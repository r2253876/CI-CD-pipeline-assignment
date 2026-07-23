# Every environment (dev/staging/prod) gets FULLY SEPARATE infrastructure —
# its own VPC, EKS cluster, ECR repo, Jenkins host, SonarQube host, KMS
# keys, and Secrets Manager secret — selected by picking a Terraform
# workspace before every plan/apply:
#
#   terraform workspace new dev        # first time only
#   terraform workspace select dev
#   terraform apply -var-file=environments/dev.tfvars
#
# Workspaces isolate STATE for you (same S3 backend, a separate state file
# per workspace via the automatic "env:/<workspace>/..." key prefix — see
# backend.tf) but do nothing about resource NAMES. Left alone, "dev" and
# "staging" would both try to create an IAM role/ECR repo/KMS alias/Secrets
# Manager secret with the exact same name in the exact same AWS account —
# all four of those are account-and-region-unique, so the second
# `terraform apply` would fail outright (or worse, silently start fighting
# the first workspace over the same resource). Every resource in this
# stack is therefore named from local.name_prefix below, not from
# var.project_name directly.
#
# Only "dev" has actually been applied and tested by this project so far.
# staging and prod are fully wired up (environments/staging.tfvars.example,
# environments/prod.tfvars.example, and the per-environment sizing in
# variables.tf's environment_config) but deliberately left uncreated until
# you're ready for them — see terraform/README.md, "Adding another
# environment."

locals {
  environment = terraform.workspace

  # e.g. "devops-assignment-dev" — every IAM role, KMS alias, security
  # group, and instance Name tag in this stack is built from this, so
  # `aws iam list-roles` / the console stay readable even once staging and
  # prod exist side by side with dev in the same account.
  name_prefix = "${var.project_name}-${local.environment}"

  # Given their own explicit base-name variables (rather than just reusing
  # name_prefix) because they're referenced by name from OUTSIDE this
  # stack — the Jenkinsfile, kubectl, docker — where "which project" and
  # "which environment" are both worth reading at a glance.
  cluster_name  = "${var.cluster_name}-${local.environment}"
  ecr_repo_name = "${var.ecr_repository_name}-${local.environment}"

  # Secrets Manager secret names are account+region unique too. Each
  # environment's Helm release points at its own path via
  # helm/devops-sample-api/values-<env>.yaml's secret.externalSecrets.remoteRefKey
  # — keep the two in sync if you ever rename this.
  app_secret_name = "devops-sample-api/${local.environment}/api-key"

  # Per-environment sizing, looked up once here so the rest of the stack
  # just reads local.env_config.* instead of indexing var.environment_config
  # in five different files.
  env_config = var.environment_config[local.environment]
}

# Fails plan/apply immediately, with an actionable message, instead of
# silently provisioning under Terraform's implicit "default" workspace —
# which matches none of the environment_config keys and would otherwise
# fail much later and less clearly (a "map does not have key ''" error
# deep inside eks.tf or jenkins.tf).
check "valid_workspace" {
  assert {
    condition     = contains(keys(var.environment_config), terraform.workspace)
    error_message = "No environment_config entry for Terraform workspace '${terraform.workspace}'. Run `terraform workspace select dev` (or `terraform workspace new dev` the first time) before planning or applying — see terraform/README.md."
  }
}
