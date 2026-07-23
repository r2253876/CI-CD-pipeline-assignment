# Asymmetric KMS key used by cosign to sign every image Jenkins pushes to
# ECR, and by Kyverno (k8s-policies/kyverno/verify-image-signature.yaml)
# to verify that signature at admission time before a pod is allowed to
# run. Neither side ever has a private key file — Jenkins calls
# kms:Sign, Kyverno calls kms:GetPublicKey/kms:DescribeKey, both via their
# own scoped IAM identity (instance profile / IRSA respectively).
#
# ECC_NIST_P256 is the curve cosign's AWS KMS provider expects.

resource "aws_kms_key" "cosign_signing" {
  description              = "cosign image-signing key for ${local.name_prefix}"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "cosign_signing" {
  name          = "alias/${local.name_prefix}-cosign-signing"
  target_key_id = aws_kms_key.cosign_signing.key_id
}
