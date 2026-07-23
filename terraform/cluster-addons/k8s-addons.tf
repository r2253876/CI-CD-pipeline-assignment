# Cluster add-ons — AWS Load Balancer Controller, Metrics Server, External
# Secrets Operator. Applied here (a separate stack/state from ../, the
# root stack that creates the cluster) specifically so the
# kubernetes/helm/kubectl providers in providers.tf can look the cluster
# up by name via a data source instead of depending on a resource being
# created in the same apply — see providers.tf's comment for why that
# matters. The IRSA roles these add-ons assume all live in the root
# stack's ../iam.tf; this file only reads their ARNs back via remote
# state.

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.root.outputs.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.root.outputs.alb_controller_role_arn
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.9.20"

  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.root.outputs.external_secrets_role_arn
  }
}

# Cluster-wide pointer telling External Secrets Operator where to read
# from (AWS Secrets Manager, authenticated via the IRSA role above — no
# access key/secret key configured anywhere in this resource). Matches
# `secret.externalSecrets.secretStoreRef` in
# ../../helm/devops-sample-api/values.yaml. kubectl_manifest (not the
# native kubernetes_manifest) — see versions.tf's comment on why.
resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secretsmanager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}
