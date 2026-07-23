output "environment" {
  value       = local.environment
  description = "The Terraform workspace this apply ran against — confirms you're looking at the right environment's outputs, since dev/staging/prod now each have entirely separate infrastructure."
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Browse to http://<this>:8080 once user-data finishes (~3-5 min after apply)."
}

output "jenkins_iam_role_arn" {
  value = aws_iam_role.jenkins.arn
}

output "alb_controller_role_arn" {
  value       = module.alb_controller_irsa.iam_role_arn
  description = "Read by ../cluster-addons/ via terraform_remote_state — the ALB controller's IRSA role."
}

output "external_secrets_role_arn" {
  value       = module.external_secrets_irsa.iam_role_arn
  description = "Read by ../cluster-addons/ via terraform_remote_state — External Secrets Operator's IRSA role."
}

output "kyverno_role_arn" {
  value       = module.kyverno_irsa.iam_role_arn
  description = "Read by ../cluster-addons/ via terraform_remote_state — Kyverno admission controller's verify-only IRSA role."
}

output "karpenter_iam_role_arn" {
  value       = module.karpenter.iam_role_arn
  description = "Read by ../cluster-addons/ via terraform_remote_state — Karpenter controller's IRSA role, annotated onto its kube-system:karpenter service account."
}

output "karpenter_node_iam_role_name" {
  value       = module.karpenter.node_iam_role_name
  description = "Read by ../cluster-addons/'s EC2NodeClass (via the ec2nodeclass.yaml.tpl template) — the IAM role instances Karpenter launches assume through the instance profile it manages at runtime."
}

output "karpenter_queue_name" {
  value       = module.karpenter.queue_name
  description = "Read by ../cluster-addons/ via terraform_remote_state — the SQS queue Karpenter watches for spot interruption / rebalance / instance-state-change notifications."
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.app_api_key.arn
}

output "ssm_session_command" {
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.aws_region}"
  description = "Access the Jenkins host without SSH keys or an open port 22."
}

output "sonarqube_url" {
  value       = "http://${aws_instance.sonarqube.public_ip}:9000"
  description = "Default login is admin/admin — SonarQube forces a password change on first login. Takes ~2-3 min after apply for the containers to finish starting."
}

output "sonarqube_ssm_session_command" {
  value       = "aws ssm start-session --target ${aws_instance.sonarqube.id} --region ${var.aws_region}"
}

output "cosign_kms_key_arn" {
  value       = aws_kms_key.cosign_signing.arn
  description = "The raw key ARN. For cosign/Kyverno's --key value, use the cosign_key_ref output instead — it's already in the awskms:///alias/... form both of those expect."
}

output "cosign_key_ref" {
  value       = "awskms:///${aws_kms_alias.cosign_signing.name}"
  description = "Pass directly as cosign's --key value (Jenkinsfile's COSIGN_KEY_REF). Read by ../cluster-addons/ via terraform_remote_state for Kyverno's verify-image-signature policy."
}
