# The application's API_KEY, generated randomly so its value never has to
# be typed into a terraform.tfvars file, committed to git, or pasted into
# Jenkins. Terraform only ever writes it into Secrets Manager (encrypted at
# rest with a customer-managed KMS key); the running pod later reads it
# back out via External Secrets Operator (iam.tf + k8s-addons.tf), using
# IAM auth, not a copy-pasted value.

resource "random_password" "app_api_key" {
  length  = 40
  special = false # keep it shell/env-var friendly
}

resource "aws_kms_key" "app_secrets" {
  description             = "Encrypts application secrets for ${local.name_prefix}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "app_secrets" {
  name          = "alias/${local.name_prefix}-app-secrets"
  target_key_id = aws_kms_key.app_secrets.key_id
}

resource "aws_secretsmanager_secret" "app_api_key" {
  name       = local.app_secret_name
  kms_key_id = aws_kms_key.app_secrets.arn

  # A short recovery window is fine for a training exercise; production
  # would typically use the default 30 days.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_api_key" {
  secret_id     = aws_secretsmanager_secret.app_api_key.id
  secret_string = random_password.app_api_key.result
}

# To rotate this value later, WITHOUT ever having it pass through your
# shell history or a Terraform variable:
#   aws secretsmanager put-secret-value \
#     --secret-id devops-sample-api/<environment>/api-key \
#     --secret-string "$(openssl rand -hex 20)"
# (substitute the actual workspace name — dev/staging/prod — matching the
# secret this stack created, e.g. devops-sample-api/dev/api-key)
# External Secrets Operator's refreshInterval (1h, set in
# helm/devops-sample-api/values.yaml) picks up the new value automatically
# and the ExternalSecret updates the Kubernetes Secret in place — no
# redeploy needed for the value to change, only for the app to notice it
# if it caches the value at startup (this sample app reads it once at
# startup, so a rollout restart is required to pick up a rotation;
# document that trade-off for real deployments and consider re-reading on
# each request or on SIGHUP if the secret changes often).
