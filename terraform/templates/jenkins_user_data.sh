#!/bin/bash
# Runs once, automatically, on first boot of the Jenkins EC2 instance
# (via EC2 user-data / cloud-init). Installs every tool the pipeline
# needs. Deliberately does NOT run `aws configure` anywhere — the
# instance profile attached in iam.tf supplies AWS credentials
# automatically to both the ec2-user and jenkins Linux users via the
# EC2 instance metadata service (IMDSv2), so there is no access key to
# type in, store, or leak.
set -euxo pipefail

exec > >(tee /var/log/user-data.log) 2>&1

dnf update -y
dnf install -y java-17-amazon-corretto git unzip

# --- Jenkins ---
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins
systemctl enable jenkins

# --- Docker ---
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user
usermod -aG docker jenkins

# --- Node.js, pinned to the EXACT version app/package.json's engines.node
# and app/Dockerfile's FROM lines require (policy/node_version.rego checks
# all three agree). NodeSource's setup script only lets you pick a major
# stream (whatever the latest 20.x happens to be that day) — that is not
# precise enough here, so this downloads the exact official build instead.
NODE_VERSION=20.15.1
curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
mkdir -p /usr/local/lib/nodejs
tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-x64/bin/node /usr/local/bin/node
ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-x64/bin/npm /usr/local/bin/npm
ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-x64/bin/npx /usr/local/bin/npx

# --- AWS CLI v2 ---
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# --- kubectl (matches the cluster_version in variables.tf) ---
curl -s -LO "https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# --- Helm ---
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x /tmp/get_helm.sh
/tmp/get_helm.sh

# --- Trivy (dependency/filesystem scan AND Docker image scan — one tool,
# both jobs; see the Jenkinsfile's "Dependency & Filesystem Scan" and
# "Docker Image Scan" stages) ---
TRIVY_VERSION=0.53.0
curl -fsSL "https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh" \
  | sh -s -- -b /usr/local/bin "v${TRIVY_VERSION}"

# --- Conftest (runs the OPA/Rego policies in policy/ against the
# Dockerfile, package.json, and rendered Helm manifests) ---
CONFTEST_VERSION=0.55.0
curl -fsSL -o /tmp/conftest.tar.gz \
  "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
tar -xzf /tmp/conftest.tar.gz -C /tmp conftest
mv /tmp/conftest /usr/local/bin/conftest

# --- cosign (signs every pushed image using the AWS KMS key in
# signing.tf — via the instance profile, no private key file involved) ---
COSIGN_VERSION=2.4.0
curl -fsSL -o /usr/local/bin/cosign \
  "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
chmod +x /usr/local/bin/cosign

# --- sonar-scanner CLI (talks to the SonarQube instance from sonarqube.tf) ---
SONAR_SCANNER_VERSION=6.2.1.4610
curl -fsSL -o /tmp/sonar-scanner.zip \
  "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"
unzip -q /tmp/sonar-scanner.zip -d /opt
ln -sf "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner" /usr/local/bin/sonar-scanner

# Jenkins needs to start AFTER the docker group membership above exists,
# and this is also the point at which the instance profile becomes usable
# by anything running under the jenkins user.
systemctl start jenkins

echo "user-data bootstrap complete" > /var/log/user-data-complete.log
