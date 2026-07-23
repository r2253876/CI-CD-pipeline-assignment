# ---------------------------------------------------------------------------
# 1. Jenkins EC2 instance role — replaces long-lived IAM user access keys.
#    The AWS CLI/SDK on the instance auto-discovers these credentials via
#    IMDSv2; they rotate automatically roughly every 6 hours and are never
#    written to disk, never appear in `aws configure`, and can't be copied
#    off the box the way a static access key can.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "jenkins_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${local.name_prefix}-jenkins-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.jenkins_assume_role.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${local.name_prefix}-jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}

# Least privilege: this role can push/pull ONE named ECR repository,
# describe/authenticate to ONE named EKS cluster, and identify itself.
# It cannot create/delete other AWS resources, read other secrets, or
# touch IAM — deliberately narrower than the "AdministratorAccess" shortcut
# used for the one-time human bootstrap step in the runbook.
data "aws_iam_policy_document" "jenkins_permissions" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this specific action does not support resource-level restriction
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = [module.eks.cluster_arn]
  }

  statement {
    sid       = "WhoAmI"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # cosign signing — scoped to the ONE signing key (signing.tf), nothing
  # else in KMS. Jenkins can sign with this key; it cannot decrypt data
  # encrypted under any other key in the account, cannot create keys, and
  # cannot change this key's policy.
  statement {
    sid       = "CosignImageSigning"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [aws_kms_key.cosign_signing.arn]
  }

  # SonarQube analysis — Jenkins only needs to reach the scanner's HTTP
  # API (see sonarqube.tf), which requires no AWS permissions at all; this
  # statement intentionally does not exist. Auth to SonarQube itself is a
  # token credential (see the "Adding DevSecOps Controls" document,
  # section "The one remaining stored secret").
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "${local.name_prefix}-jenkins-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_permissions.json
}

# Systems Manager Session Manager as a backup access path to the instance
# that doesn't depend on the SSH key pair or an open port 22 at all.
resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------------------------------------------
# 2. Map the Jenkins role into Kubernetes RBAC via EKS access entries — the
#    modern replacement for hand-editing the aws-auth ConfigMap. Scoped to
#    only the namespaces the app actually deploys into, with the built-in
#    "edit" policy (create/update workloads, no RBAC/secret-reading beyond
#    its own namespace, no cluster-admin).
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_edit" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  # Now that each environment gets its OWN dedicated cluster (see
  # locals.tf), this Jenkins host's role only needs — and only gets —
  # "edit" on the one namespace matching the environment its own cluster
  # belongs to. Under the old shared-cluster model this list held all
  # three namespaces because one Jenkins deployed to all three; that's no
  # longer true, so the blast radius of a compromised Jenkins host is now
  # "this one environment's app namespace on this one environment's
  # cluster," not "every environment's namespace on the shared cluster."
  access_scope {
    type       = "namespace"
    namespaces = ["devops-sample-api-${local.environment}"]
  }
}

# ---------------------------------------------------------------------------
# 3. IRSA role for the AWS Load Balancer Controller — the controller pod
#    assumes this role via its Kubernetes service account token (no AWS
#    credentials of any kind stored in the cluster). Uses the standard
#    community sub-module built exactly for this pattern.
#
#    This role is created HERE, not in terraform/cluster-addons/ (which is
#    what actually installs the controller that assumes it) — it's a pure
#    IAM resource that only needs module.eks.oidc_provider_arn, available
#    in this same apply, so there's no reason to push its creation into
#    the stack that talks to the live cluster. cluster-addons/ reads its
#    ARN back via the alb_controller_role_arn output, below.
# ---------------------------------------------------------------------------

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-alb-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# ---------------------------------------------------------------------------
# 4. IRSA role for External Secrets Operator — scoped to read ONLY the one
#    secret this app needs (secrets.tf), nothing else in Secrets Manager.
#    Same reasoning as #3 above for why it's created here, not in
#    terraform/cluster-addons/.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "external_secrets_permissions" {
  statement {
    sid       = "ReadOneAppSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.app_api_key.arn]
  }
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-external-secrets"

  role_policy_arns = {
    app_secret = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_policy" "external_secrets" {
  name   = "${local.name_prefix}-external-secrets-read-app-secret"
  policy = data.aws_iam_policy_document.external_secrets_permissions.json
}

# ---------------------------------------------------------------------------
# 5. IRSA role for Kyverno's admission controller — VERIFY only
#    (GetPublicKey, DescribeKey), never kms:Sign. Only Jenkins (above)
#    can sign; Kyverno can only check a signature that already exists.
#
#    Moved here from what used to be terraform/kyverno.tf, for the same
#    reason as #3/#4: pure IAM, no live cluster access needed to create
#    it. terraform/cluster-addons/kyverno.tf (which installs Kyverno
#    itself and assumes this role) reads its ARN back via the
#    kyverno_role_arn output, below.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kyverno_kms_verify" {
  statement {
    sid       = "VerifyOnly"
    actions   = ["kms:GetPublicKey", "kms:DescribeKey"]
    resources = [aws_kms_key.cosign_signing.arn]
  }
}

resource "aws_iam_policy" "kyverno_kms_verify" {
  name   = "${local.name_prefix}-kyverno-kms-verify"
  policy = data.aws_iam_policy_document.kyverno_kms_verify.json
}

module "kyverno_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-kyverno-admission-controller"

  role_policy_arns = {
    kms_verify = aws_iam_policy.kyverno_kms_verify.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kyverno:kyverno-admission-controller"]
    }
  }
}
