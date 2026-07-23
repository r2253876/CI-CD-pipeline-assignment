# Karpenter — node-level autoscaling to complement the app's existing
# pod-level autoscaling (helm/devops-sample-api/templates/hpa.yaml).
# capacity pool: min/max/desired sizes you set by hand in
# variables.tf's environment_config, with nothing watching for
# unschedulable pods and adding nodes in response. The HPA can already
# ask for more pod replicas under load, but if the existing nodes don't
# have room, those extra pods just sit Pending — nothing in this stack
# reacts to that today.
#
# Karpenter closes that gap: it watches for Pending pods, and when it
# finds ones it can't place, it launches a right-sized EC2 instance
# (picked from the flexible instance-family/generation constraints in
# k8s-policies/karpenter/nodepool.yaml, not a single hardcoded instance
# type) and joins it to the cluster within about a minute — no separate
# Cluster Autoscaler, no per-AZ ASG to hand-tune.
#
# This file only creates the IAM/AWS-account side (controller IRSA role,
# node IAM role, SQS interruption queue, EKS access entry for nodes
# Karpenter launches) — the same reasoning as the ALB controller/External
# Secrets/Kyverno IRSA roles above: it only needs
# module.eks.oidc_provider_arn, which is available in this same apply,
# so there's no reason to push it into cluster-addons/ (which is reserved
# for things that need the cluster to already be live). Installing the
# Karpenter controller itself (a Helm release) and its EC2NodeClass/
# NodePool (CRDs the controller must already be running to accept) is in
# cluster-addons/karpenter.tf, which reads this file's outputs back via
# terraform_remote_state — see that file's comment.
#
# The standard-workers managed node group is deliberately left as-is,
# not replaced. Managed node groups are more predictable for the handful
# of "must always be running" system pods (Karpenter's own controller,
# CoreDNS, the ALB controller, Kyverno, External Secrets) — Karpenter
# needs somewhere stable to run *before* it can provision anything, so
# it never schedules itself onto nodes it launched. Once you've verified
# Karpenter is provisioning nodes correctly for your app's workload, you
# can shrink standard-workers' min/max/desired in variables.tf down to
# just what the system pods need and let Karpenter own the rest — that's
# a follow-up tuning step, not required for this to work.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24" # same major version as the `eks` module above, for compatible outputs

  cluster_name = module.eks.cluster_name

  # Matches the chart version pinned in cluster-addons/karpenter.tf — v1.x
  # of the Karpenter chart expects the controller IAM policy shaped for
  # the stable karpenter.sh/v1 + karpenter.k8s.aws/v1 CRDs. If you ever
  # pin an older 0.3x chart there, set this back to false.
  enable_v1_permissions = true

  # Same 38-character name_prefix issue called out in eks.tf's
  # iam_role_name comment — explicit names, no prefix, for both roles
  # this module creates.
  iam_role_name            = "${local.name_prefix}-karpenter-controller"
  iam_role_use_name_prefix = false

  node_iam_role_name            = "${local.name_prefix}-karpenter-node-role"
  node_iam_role_use_name_prefix = false

  # Lets Karpenter's controller manage its own EC2 instance profiles at
  # runtime (create_instance_profile = false, the module default) instead
  # of Terraform pre-creating one — the module already grants the
  # controller role the narrow iam:*InstanceProfile permissions that
  # requires, scoped to profiles it creates itself.
  create_instance_profile = false

  # EKS access entry (API_AND_CONFIG_MAP auth mode, same as the Jenkins
  # entry in iam.tf) mapping the node role so instances Karpenter launches
  # can actually join the cluster — without this, kubelet bootstrap on a
  # Karpenter-launched node would fail auth against the API server.
  create_access_entry = true

  # SQS queue + EventBridge rules for spot interruption, rebalance
  # recommendation, and instance-state-change notices. Created regardless
  # of whether nodepool.yaml currently requests spot capacity, so turning
  # spot on later (see that file's comment) is a one-line NodePool change,
  # not a new apply of this module.
  enable_spot_termination = true

  # Same IRSA pattern as alb_controller_irsa / external_secrets_irsa /
  # kyverno_irsa above — the controller pod assumes this role via its
  # service account token, no static AWS credentials in the cluster.
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:karpenter"]
    }
  }

  tags = {
    Project     = var.project_name
    Environment = local.environment
  }
}

# ---------------------------------------------------------------------------
# Resource discovery tags — how Karpenter finds which subnets and security
# groups it's allowed to launch nodes into, without you hand-listing subnet
# IDs in nodepool.yaml. EC2NodeClass (k8s-policies/karpenter/ec2nodeclass.yaml.tpl)
# selects on this exact tag.
# ---------------------------------------------------------------------------

resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each = toset(module.vpc.private_subnets) # Karpenter-launched nodes are private, same as standard-workers

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}

resource "aws_ec2_tag" "karpenter_node_security_group_discovery" {
  # The shared node security group the `eks` module already creates and
  # attaches to standard-workers — reusing it means Karpenter-launched
  # nodes get the exact same cluster networking rules as the managed
  # node group, with no second security group to keep in sync.
  resource_id = module.eks.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}
