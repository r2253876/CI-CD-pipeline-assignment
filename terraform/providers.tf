provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}

# No kubernetes/helm/kubectl provider blocks here anymore — this stack no
# longer installs anything onto the cluster directly. It used to (Kyverno,
# the ALB controller, Metrics Server, External Secrets), configuring those
# providers from module.eks's own outputs, which only works reliably
# AFTER the cluster already exists in state — a brand new environment's
# first apply would fail with "Kubernetes cluster unreachable: invalid
# configuration: no configuration has been provided," because
# depends_on = [module.eks] sequences resource *creation*, not *provider
# configuration*, and Terraform must resolve a provider's config before
# planning anything that uses it.
#
# Everything that needs live cluster access now lives in
# ../cluster-addons/, a separate stack applied after this one, whose
# providers.tf looks the cluster up with `data "aws_eks_cluster"` instead
# of a same-apply resource reference — a data source requires the cluster
# to already exist, which it always does there. See
# ../cluster-addons/README.md for the full story and the apply order.
