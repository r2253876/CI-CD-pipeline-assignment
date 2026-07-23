data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Looking this up (instead of passing var.jenkins_key_pair_name straight
# into aws_instance.key_name) turns a missing key pair into a clear
# failure during `terraform plan` — before the VPC/EKS cluster get
# created — instead of an InvalidKeyPair.NotFound error from RunInstances
# 15-20 minutes into `apply`, after everything ahead of it already
# succeeded. Key pairs are region-scoped, so this also catches "the key
# exists, just not in aws_region" at the same point.
data "aws_key_pair" "jenkins" {
  key_name = var.jenkins_key_pair_name
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = local.env_config.jenkins_instance_type
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = data.aws_key_pair.jenkins.key_name

  associate_public_ip_address = true

  # IMDSv2 only — the older, SSRF-vulnerable IMDSv1 is disabled, since this
  # instance holds an IAM role and IMDS is exactly what a request-forgery
  # attack against the app would try to reach.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data                  = file("${path.module}/templates/jenkins_user_data.sh")
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name_prefix}-jenkins"
  }
}
