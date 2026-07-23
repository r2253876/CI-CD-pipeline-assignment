# Partial backend configuration — the bucket/table names depend on the AWS
# account ID (see bootstrap/), so they are NOT hardcoded here. Supply them
# at `terraform init` time:
#
#   terraform init \
#     -backend-config="bucket=devops-assignment-tfstate-<ACCOUNT_ID>" \
#     -backend-config="dynamodb_table=devops-assignment-tflock" \
#     -backend-config="region=ap-south-1"
#
# (Exact values are printed as outputs by `terraform apply` in bootstrap/.)
#
# This same bucket/table is shared across every environment — that's
# intentional and requires no per-environment backend config. Once you
# run `terraform workspace select <env>`, Terraform automatically stores
# that workspace's state under its own key
# (env:/<workspace>/devops-assignment/terraform.tfstate inside this
# bucket), so dev/staging/prod each get a fully separate state file and
# DynamoDB lock without you doing anything beyond selecting the workspace
# first. See terraform/README.md.

terraform {
  backend "s3" {
    key     = "devops-assignment/terraform.tfstate"
    encrypt = true
  }
}
