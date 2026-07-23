# Standard, widely-used community module — avoids hand-rolling ~15
# resources (subnets, route tables, NAT gateway, IGW) that have well-known
# correct shapes for EKS. Pinned to a specific major version.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT for the whole exercise keeps cost down; use per-AZ NAT for real prod HA
  enable_dns_hostnames = true

  # Required tags so the EKS-managed AWS Load Balancer Controller and the
  # in-cluster scheduler know which subnets to use for internet-facing vs.
  # internal load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
