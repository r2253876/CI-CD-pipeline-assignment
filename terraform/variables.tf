variable "aws_region" {
  description = "AWS region for every resource in this stack."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name used to namespace/tag every resource."
  type        = string
  default     = "devops-assignment"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created for this exercise."
  type        = string
  default     = "10.42.0.0/16"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "devops-assignment-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.35"
}

variable "ecr_repository_name" {
  description = "Base name for the per-environment ECR repo — locals.tf appends the environment, e.g. devops-sample-api-dev. Must match the ECR_REPO value the Jenkinsfile derives from params.DEPLOY_ENV."
  type        = string
  default     = "devops-sample-api"
}

variable "environment_config" {
  description = <<-EOT
    Per-environment sizing, keyed by Terraform workspace name (dev/staging/prod)
    and looked up via local.env_config in locals.tf. Extend or override this map
    rather than adding new flat variables when you bring up staging/prod for
    real — it's what keeps dev from ever accidentally inheriting prod's node
    counts, or vice versa.

    Only "dev" has actually been applied. staging/prod rows exist so the stack
    is ready to provision them, but their instance types/sizes below are a
    starting point, not something this project has load-tested.
  EOT
  type = map(object({
    node_instance_types       = list(string)
    node_min_size             = number
    node_max_size             = number
    node_desired_size         = number
    jenkins_instance_type     = string
    sonarqube_instance_type   = string
    sonarqube_data_volume_size = number
  }))

  default = {
    dev = {
      node_instance_types        = ["t3.medium"]
      node_min_size               = 2
      node_max_size                = 4
      node_desired_size            = 2
      jenkins_instance_type        = "t3.medium"
      sonarqube_instance_type      = "t3.medium"
      sonarqube_data_volume_size   = 20
    }
    staging = {
      node_instance_types        = ["t3.medium"]
      node_min_size               = 2
      node_max_size                = 6
      node_desired_size            = 2
      jenkins_instance_type        = "t3.medium"
      sonarqube_instance_type      = "t3.medium"
      sonarqube_data_volume_size   = 20
    }
    prod = {
      node_instance_types        = ["t3.large"]
      node_min_size               = 3
      node_max_size                = 10
      node_desired_size            = 3
      jenkins_instance_type        = "t3.large"
      sonarqube_instance_type      = "t3.large"
      sonarqube_data_volume_size   = 50
    }
  }
}

variable "jenkins_key_pair_name" {
  description = "Name of an EXISTING EC2 key pair, used only for break-glass SSH access — day-to-day AWS API auth uses the instance profile, not this key."
  type        = string
}

variable "admin_cidr" {
  description = "Your IP (as x.x.x.x/32) or office/VPN range — the ONLY range allowed to reach Jenkins' SSH (22) and web UI (8080) ports. Never leave this as 0.0.0.0/0."
  type        = string

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must not be 0.0.0.0/0 — that exposes Jenkins' SSH and web UI to the entire internet. Use your own public IP as x.x.x.x/32 (e.g. `curl https://checkip.amazonaws.com`) or a VPN/office CIDR."
  }

  validation {
    # 192.0.2.0/24, 198.51.100.0/24, and 203.0.113.0/24 are RFC 5737's
    # "documentation" ranges — never real, routable addresses. They only
    # show up here because they're the placeholder values in
    # environments/*.tfvars.example, so seeing one at plan time almost
    # always means a copy that was never actually edited. AWS would
    # otherwise reject the EKS-side equivalent of this with a bare
    # InvalidParameterException 15+ minutes into `apply`, once the
    # cluster create call finally runs.
    condition = !anytrue([
      for prefix in ["192.0.2.", "198.51.100.", "203.0.113."] :
      startswith(var.admin_cidr, prefix)
    ])
    error_message = "admin_cidr still looks like the RFC 5737 documentation/example placeholder from environments/*.tfvars.example (e.g. 203.0.113.10/32) — that's not a real address. Replace it with your own public IP or VPN/office CIDR before applying."
  }
}

variable "eks_public_access_cidrs" {
  description = "CIDR ranges allowed to reach the EKS public API endpoint (your admin_cidr plus the Jenkins host's IP end up here automatically). Kept separate from admin_cidr so you can widen cluster API access without touching SSH exposure, or vice versa."
  type        = list(string)

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "eks_public_access_cidrs must not include 0.0.0.0/0 — that exposes the EKS API server to the entire internet. List your own public IP(s) or a VPN/office CIDR instead."
  }

  validation {
    # Same RFC 5737 documentation-range check as admin_cidr, above — this
    # is exactly the CIDR AWS's EKS CreateCluster call rejects with
    # "InvalidParameterException: The following CIDRs are not allowed in
    # publicAccessCidrs" if environments/*.tfvars.example's placeholder
    # value is applied unedited.
    condition = alltrue([
      for cidr in var.eks_public_access_cidrs :
      !anytrue([for prefix in ["192.0.2.", "198.51.100.", "203.0.113."] : startswith(cidr, prefix)])
    ])
    error_message = "eks_public_access_cidrs still contains the RFC 5737 documentation/example placeholder from environments/*.tfvars.example (e.g. 203.0.113.10/32) — AWS rejects it outright when creating the cluster. Replace it with your own public IP(s) or a VPN/office CIDR."
  }
}
