variable "aws_region" {
  description = "AWS region — must match the root stack's aws_region for the environment you're targeting."
  type        = string
  default     = "ap-south-1"
}

variable "tfstate_bucket" {
  description = <<-EOT
    The same S3 bucket the root stack's backend.tf uses (see bootstrap/'s
    output, or ../backend.tf's own comment). Needed here as an actual
    variable, not just a -backend-config flag, because this stack reads
    the root stack's outputs via a terraform_remote_state DATA SOURCE
    (config = {...}), and data source configuration can't be filled in by
    -backend-config partial-backend overrides the way this file's own
    `terraform { backend "s3" {...} }` block can — Terraform only applies
    that mechanism to the backend block itself. You'll type this bucket
    name twice (once at `terraform init`, once here) for that reason.
  EOT
  type        = string
}
