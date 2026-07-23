# SonarQube Community Edition, self-hosted on its own EC2 instance
# (Docker Compose: SonarQube + Postgres), kept off the EKS cluster to
# avoid the extra ingress/PVC/storage-class overhead for a single scanner
# instance. Provides the static code analysis + Quality Gate the
# Jenkinsfile's "SonarQube Analysis" and "Quality Gate" stages call out to.

resource "random_password" "sonar_db_password" {
  length  = 32
  special = false
}

# Stored for reference/rotation, even though only this instance's own
# user-data ever reads it directly (baked in at boot, not fetched at
# runtime — see the note in sonarqube_user_data.sh.tpl about rotating it).
resource "aws_secretsmanager_secret" "sonar_db_password" {
  name                     = "${local.name_prefix}/sonarqube-db-password"
  kms_key_id               = aws_kms_key.app_secrets.arn
  recovery_window_in_days  = 0
}

resource "aws_secretsmanager_secret_version" "sonar_db_password" {
  secret_id     = aws_secretsmanager_secret.sonar_db_password.id
  secret_string = random_password.sonar_db_password.result
}

data "aws_iam_policy_document" "sonarqube_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sonarqube" {
  name               = "${local.name_prefix}-sonarqube-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.sonarqube_assume_role.json
}

resource "aws_iam_instance_profile" "sonarqube" {
  name = "${local.name_prefix}-sonarqube-instance-profile"
  role = aws_iam_role.sonarqube.name
}

# SonarQube itself makes no AWS API calls — this instance's role exists
# purely so you can reach it via SSM Session Manager instead of opening
# SSH.
resource "aws_iam_role_policy_attachment" "sonarqube_ssm" {
  role       = aws_iam_role.sonarqube.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_security_group" "sonarqube" {
  name        = "${local.name_prefix}-sonarqube-sg"
  description = "SonarQube UI/API - reachable from Jenkins (scans + webhook) and admin_cidr (browser) only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "SonarQube UI/API from Jenkins (sonar-scanner pushes results here)"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  ingress {
    description = "SonarQube UI from your admin IP (initial setup, browsing results, configuring the webhook)"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The reverse path: SonarQube calling Jenkins' webhook endpoint
# (http://<jenkins>:8080/sonarqube-webhook/) so `waitForQualityGate` in
# the Jenkinsfile doesn't have to poll.
resource "aws_security_group_rule" "jenkins_allow_sonarqube_webhook" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins.id
  source_security_group_id = aws_security_group.sonarqube.id
  description               = "SonarQube webhook callback for Quality Gate status"
}

resource "aws_ebs_volume" "sonarqube_data" {
  availability_zone = data.aws_availability_zones.available.names[1]
  size              = local.env_config.sonarqube_data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name_prefix}-sonarqube-data"
  }
}

resource "aws_instance" "sonarqube" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = local.env_config.sonarqube_instance_type
  subnet_id              = module.vpc.public_subnets[1]
  vpc_security_group_ids = [aws_security_group.sonarqube.id]
  iam_instance_profile   = aws_iam_instance_profile.sonarqube.name
  key_name               = data.aws_key_pair.jenkins.key_name

  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/sonarqube_user_data.sh.tpl", {
    sonar_db_password = random_password.sonar_db_password.result
  })
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name_prefix}-sonarqube"
  }
}

resource "aws_volume_attachment" "sonarqube_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.sonarqube_data.id
  instance_id = aws_instance.sonarqube.id
}
