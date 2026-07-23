apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
  annotations:
    policies.kyverno.io/title: Verify Image Signatures (cosign / AWS KMS)
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      Every image deployed to the devops-sample-api-* namespaces must be
      signed by this project's AWS KMS signing key (terraform/signing.tf).
      This is the in-cluster backstop for the Jenkinsfile's own "Sign
      Image"/"Verify Image Signature" stages — it catches anything
      deployed by a path that bypasses Jenkins entirely: kubectl apply by
      hand, a different pipeline, or a compromised credential that has
      cluster access but not KMS sign access. Rendered from this .tpl by
      terraform/kyverno.tf so the KMS key reference always matches
      signing.tf's actual key, never hand-copied.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-kms-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - devops-sample-api-dev
                - devops-sample-api-staging
                - devops-sample-api-prod
      verifyImages:
        - imageReferences:
            - "${ecr_registry}/devops-sample-api*"
          attestors:
            - count: 1
              entries:
                - keys:
                    kms: "${cosign_key_ref}"
          required: true
          mutateDigest: true
