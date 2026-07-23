# Karpenter — installs the controller itself and the two CRDs
# (EC2NodeClass, NodePool) that tell it what and how to launch. The
# IAM side (controller IRSA role, node IAM role, SQS interruption queue,
# EKS access entry) lives in the ROOT stack's ../karpenter.tf, for the
# same reason the ALB controller/External Secrets/Kyverno IRSA roles do
# — it's pure IAM, needs no live cluster access, and this file only reads
# those ARNs/names back via terraform_remote_state. See ../karpenter.tf's
# comment for the full picture of what Karpenter adds and why.
#
# Chart source is the OCI registry Karpenter publishes to directly (no
# separate `helm repo add` needed, unlike the other add-ons in
# k8s-addons.tf) — this is how upstream has distributed the chart since
# the karpenter.sh Helm repo was retired.

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "kube-system"
  version    = "1.1.1" # check https://github.com/aws/karpenter-provider-aws/releases for the current stable tag before applying

  set {
    name  = "settings.clusterName"
    value = data.terraform_remote_state.root.outputs.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = data.terraform_remote_state.root.outputs.karpenter_queue_name
  }
  set {
    name  = "serviceAccount.name"
    value = "karpenter"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.root.outputs.karpenter_iam_role_arn
  }

  # Karpenter's own pod has to land somewhere that already exists before
  # it can provision anything — it schedules onto standard-workers (the
  # managed node group from ../eks.tf) like every other kube-system
  # add-on in this stack, never onto a node it launched itself.
}

# --- EC2NodeClass / NodePool ---
# EC2NodeClass is rendered from its .tpl so the node IAM role and
# discovery tag value always match what ../karpenter.tf actually created,
# rather than being hand-copied here and silently drifting — same
# pattern as kyverno.tf's verify-image-signature.yaml.tpl.

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/../../k8s-policies/karpenter/ec2nodeclass.yaml.tpl", {
    cluster_name = data.terraform_remote_state.root.outputs.cluster_name
    node_role    = data.terraform_remote_state.root.outputs.karpenter_node_iam_role_name
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = file("${path.module}/../../k8s-policies/karpenter/nodepool.yaml")

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_class,
  ]
}
