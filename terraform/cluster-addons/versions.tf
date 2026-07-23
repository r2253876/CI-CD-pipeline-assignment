terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubectl = {
      # Same reasoning as the root stack used to have: gavinbunney/kubectl's
      # kubectl_manifest applies server-side without needing the target
      # CRD's schema at PLAN time, unlike the native kubernetes_manifest
      # resource. Kept here because the Kyverno ClusterPolicies and the
      # ExternalSecrets ClusterSecretStore are both CRD-backed.
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
