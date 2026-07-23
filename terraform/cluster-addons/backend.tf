# Same shared state bucket/lock table as ../  (the root stack) — supply at
# `terraform init` time, same as the root stack:
#
#   terraform init \
#     -backend-config="bucket=devops-assignment-tfstate-<ACCOUNT_ID>" \
#     -backend-config="dynamodb_table=devops-assignment-tflock" \
#     -backend-config="region=ap-south-1"
#
# Deliberately a DIFFERENT key from the root stack's
# "devops-assignment/terraform.tfstate" — this is a separate Terraform
# root module with its own state, applied as its own step after the root
# stack. Workspaces still isolate dev/staging/prod from each other here
# too: run `terraform workspace select <env>` before every plan/apply,
# matching whichever environment's cluster you're targeting.

terraform {
  backend "s3" {
    key     = "devops-assignment-cluster-addons/terraform.tfstate"
    encrypt = true
  }
}
