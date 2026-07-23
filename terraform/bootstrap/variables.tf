variable "aws_region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name used to namespace the bucket/table."
  type        = string
  default     = "devops-assignment"
}
