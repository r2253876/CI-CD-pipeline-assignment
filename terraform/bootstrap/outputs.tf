output "state_bucket" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "Pass this as -backend-config=\"bucket=...\" when running `terraform init` in ../"
}

output "lock_table" {
  value       = aws_dynamodb_table.tflock.name
  description = "Pass this as -backend-config=\"dynamodb_table=...\" when running `terraform init` in ../"
}

output "kms_key_arn" {
  value = aws_kms_key.tfstate.arn
}
