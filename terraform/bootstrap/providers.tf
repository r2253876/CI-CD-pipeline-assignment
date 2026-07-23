# Bootstrap stack: creates ONLY the S3 bucket + DynamoDB table that the
# main Terraform configuration (../) will use as its remote state backend.
#
# This has to be a separate, tiny Terraform stack with its own LOCAL state,
# because you cannot point Terraform at an S3 backend that doesn't exist
# yet — classic chicken-and-egg. Run this once, by hand, before anything
# else. Its own state file (bootstrap/terraform.tfstate) is small and
# low-risk enough to keep local; everything that follows uses the remote
# backend this creates.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "devops-assignment"
      ManagedBy   = "terraform"
      Component   = "tfstate-bootstrap"
    }
  }
}
