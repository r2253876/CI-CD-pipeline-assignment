# Rendered by terraform/cluster-addons/karpenter.tf's kubectl_manifest.karpenter_node_class
# — do not `kubectl apply` this file directly, its ${...} placeholders are
# Terraform template syntax, not valid YAML.
#
# EC2NodeClass — the AWS-specific half of "what kind of node." NodePool
# (nodepool.yaml, alongside this file) is the Kubernetes-generic half
# ("how many, what instance shapes, when to remove them"); together they
# replace what a launch template + ASG would otherwise do by hand.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  # Amazon Linux 2023 — the modern default AMI family for EKS-managed and
  # Karpenter-launched nodes alike; matches what the `eks` module's
  # standard-workers group also uses today.
  amiFamily: AL2023

  # The node IAM role from ../../terraform/karpenter.tf's
  # module.karpenter.node_iam_role_name — Karpenter creates and manages
  # the EC2 instance profile for this role itself at runtime (see that
  # module's create_instance_profile = false), so no instance profile name
  # is set here, just the role.
  role: ${node_role}

  # Only launch into subnets/security groups this project's own VPC/EKS
  # stack tagged for discovery (../../terraform/karpenter.tf's
  # aws_ec2_tag resources) — never "any subnet in the account tagged this
  # way," which is why the tag VALUE (not just the key) has to match this
  # cluster's name.
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}

  # Every instance Karpenter launches gets this tag too, so
  # `aws ec2 describe-instances --filters Name=tag:karpenter.sh/discovery,...`
  # (or just the console) can find them at a glance, same idea as
  # local.name_prefix tagging everything else in this stack.
  tags:
    karpenter.sh/discovery: ${cluster_name}

  # IMDSv2 required, hop limit 2 (needed for containerized workloads that
  # reach the metadata service through the pod network) — same posture
  # this project already takes on the Jenkins/SonarQube EC2 hosts.
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 40Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
