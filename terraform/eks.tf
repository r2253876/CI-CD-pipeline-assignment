# Standard community module for EKS — handles the control plane, the
# managed node group, the cluster security group, and the IAM OIDC
# provider (needed for IRSA — see iam.tf) correctly out of the box.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  # The module's default IAM role naming uses name_prefix (cluster_name +
  # "-cluster-"), and AWS caps name_prefix at 38 characters to leave room
  # for the random suffix it appends — "devops-assignment-cluster-staging"
  # alone is already 34 chars, so + "-cluster-" blows past 38. Giving it
  # an explicit, non-prefixed name sidesteps that: plain role names go up
  # to 64 characters, and this stack's longest possible name is nowhere
  # close to that.
  iam_role_name            = "${local.cluster_name}-cluster-role"
  iam_role_use_name_prefix = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids                = module.vpc.private_subnets
  control_plane_subnet_ids  = module.vpc.private_subnets

  # Public endpoint kept on so Jenkins/you can reach it without a VPN or
  # bastion — but locked to explicit CIDRs, never 0.0.0.0/0. Authorization
  # once a request reaches the endpoint is still enforced by IAM (who you
  # are) + Kubernetes RBAC (what that identity can do) via the access
  # entries in iam.tf, so this CIDR list is defense-in-depth, not the only
  # control.
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs
  cluster_endpoint_private_access      = true

  # Modern cluster access management (replaces manually editing the
  # aws-auth ConfigMap). Entries themselves are declared in iam.tf so
  # they sit next to the IAM roles they map.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    standard-workers = {
      instance_types = local.env_config.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = local.env_config.node_min_size
      max_size     = local.env_config.node_max_size
      desired_size = local.env_config.node_desired_size

      # Same 38-character name_prefix limit as the cluster role above, and
      # this default would actually be longer (cluster_name + node group
      # key + "-eks-node-group-") — same fix: explicit name, no prefix.
      iam_role_name            = "${local.name_prefix}-node-group-role"
      iam_role_use_name_prefix = false

      labels = {
        role = "standard-workers"
      }
    }
  }

  tags = {
    Project     = var.project_name
    Environment = local.environment
  }
}
