# Kyverno — Kubernetes-native policy engine, installed as an admission
# controller so every policy in k8s-policies/kyverno/ is enforced on
# anything reaching the cluster, not just what happens to go through
# Jenkins. Deliberately redundant with policy/*.rego (Conftest, CI-time):
# Conftest fails a Jenkins build fast, before an image is even pushed;
# Kyverno is what still stops a bad deploy if Jenkins is bypassed
# entirely (kubectl apply by hand, a different pipeline, a stolen
# kubeconfig with cluster access but not KMS access).

data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "3.2.6"

  # Chart v3.x splits Kyverno into per-function controllers, each with its
  # own ServiceAccount. The admission-controller is the one that runs
  # synchronously on every create/update and is what actually calls out to
  # AWS KMS during image-signature verification, so it's the one that
  # gets the IRSA role. The IRSA role is created in iam.tf.
  set {
    name  = "admissionController.serviceAccount.name"
    value = "kyverno-admission-controller"
  }

  set {
    name  = "admissionController.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.kyverno_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# ClusterPolicies
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "kyverno_restrict_image_registry" {
  yaml_body  = file("${path.module}/../k8s-policies/kyverno/restrict-image-registry.yaml")
  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_disallow_latest_tag" {
  yaml_body  = file("${path.module}/../k8s-policies/kyverno/disallow-latest-tag.yaml")
  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_resource_limits" {
  yaml_body  = file("${path.module}/../k8s-policies/kyverno/require-resource-limits.yaml")
  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_probes" {
  yaml_body  = file("${path.module}/../k8s-policies/kyverno/require-probes.yaml")
  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_disallow_privileged_and_root" {
  yaml_body  = file("${path.module}/../k8s-policies/kyverno/disallow-privileged-and-root.yaml")
  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_verify_image_signature" {
  yaml_body = templatefile(
    "${path.module}/../k8s-policies/kyverno/verify-image-signature.yaml.tpl",
    {
      ecr_registry   = local.ecr_registry
      cosign_key_ref = "awskms:///alias/${local.name_prefix}-cosign-signing"
    }
  )

  depends_on = [
    helm_release.kyverno,
    module.kyverno_irsa
  ]
}