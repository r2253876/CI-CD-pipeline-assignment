provider "aws" {
  region = var.aws_region
}

# Reads ../  (the root stack)'s outputs for the CURRENTLY SELECTED
# workspace — same environment you must `terraform workspace select`
# here before planning/applying (locals.tf's check enforces that you
# picked *some* workspace; it's on you to pick the matching one).
data "terraform_remote_state" "root" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket = var.tfstate_bucket
    key    = "devops-assignment/terraform.tfstate"
    region = var.aws_region
  }
}

# THE ACTUAL FIX, compared to how the root stack used to do this:
# these are DATA SOURCES — live AWS API lookups by name — not attributes
# of a resource being created in this same apply. A data source requires
# the thing it's looking up to already exist, which the cluster always
# does by the time this stack runs (it's a separate `terraform apply`,
# run after the root stack's). That's what makes `terraform plan`/`apply`
# here behave like any other stack — no two-phase/-target dance, ever,
# for this stack or the root one. See ../README.md for the full story on
# why the old single-stack setup couldn't do this.
data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.root.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.root.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}
