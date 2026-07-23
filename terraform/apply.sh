#!/usr/bin/env bash
# Applies the currently-selected Terraform workspace safely.
#
# WHY THIS SCRIPT EXISTS: providers.tf configures the kubernetes/helm/
# kubectl providers from module.eks's own outputs (cluster_endpoint,
# cluster_certificate_authority_data, the aws_eks_cluster_auth token) so
# that Kyverno, the ALB controller, Metrics Server, and External Secrets
# can all be installed by Terraform in the same stack that creates the
# cluster. Every helm_release/kubectl_manifest resource in kyverno.tf and
# k8s-addons.tf has depends_on = [module.eks], which correctly orders
# *resource creation*, but it does NOT help the *provider configuration*
# itself — Terraform must resolve providers.tf's host/token/CA values
# before it can plan anything that uses those providers, and on the
# very first apply of a brand new environment (a fresh `dev`, or a new
# `staging`/`prod` workspace) module.eks doesn't exist in state yet, so
# those values are unknown. That's what produces:
#
#   Error: Kubernetes cluster unreachable: invalid configuration: no
#   configuration has been provided, try setting KUBERNETES_MASTER
#   environment variable
#
# The fix is a one-time, two-phase apply for a brand new environment:
# create the cluster alone first (so its outputs become real, known
# values in state), then apply everything else. Once an environment's
# module.eks is in state, every later `terraform apply` for that same
# workspace is a normal single pass — this script detects that and
# skips the bootstrap step automatically, so it's safe to use for every
# apply, not just the first one.
#
# Usage:
#   ./apply.sh environments/dev.tfvars
#   ./apply.sh environments/staging.tfvars
#
# Prerequisites (same as a plain `terraform apply`): you've already run
# `terraform init` with the right backend config and selected the
# correct workspace (`terraform workspace select <env>`) — this script
# does not do either of those for you.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-tfvars-file>" >&2
  echo "  e.g.: $0 environments/dev.tfvars" >&2
  exit 1
fi

TFVARS="$1"
shift
EXTRA_ARGS=("$@")

if [ ! -f "$TFVARS" ]; then
  echo "error: tfvars file not found: $TFVARS" >&2
  exit 1
fi

WORKSPACE="$(terraform workspace show)"
if [ "$WORKSPACE" = "default" ]; then
  echo "error: refusing to apply against the 'default' workspace." >&2
  echo "Select an environment first: terraform workspace select dev" >&2
  exit 1
fi

echo "==> Workspace: $WORKSPACE"

EKS_IN_STATE="$(terraform state list 2>/dev/null | grep -c '^module\.eks\.' || true)"

if [ "$EKS_IN_STATE" -eq 0 ]; then
  echo "==> module.eks not found in state yet — this looks like the first"
  echo "    apply for the '$WORKSPACE' workspace. Bootstrapping the EKS"
  echo "    cluster (and its VPC dependency) on its own first, so the"
  echo "    kubernetes/helm/kubectl providers in providers.tf have real"
  echo "    values to configure themselves with:"
  echo ""
  terraform apply -var-file="$TFVARS" -target=module.eks "${EXTRA_ARGS[@]}"
  echo ""
  echo "==> Cluster is up. Continuing with the full apply (Kyverno, the"
  echo "    ALB controller, External Secrets, Jenkins/SonarQube hosts,"
  echo "    everything else)."
else
  echo "==> module.eks already exists in state — normal single-pass apply."
fi

echo ""
terraform apply -var-file="$TFVARS" "${EXTRA_ARGS[@]}"
