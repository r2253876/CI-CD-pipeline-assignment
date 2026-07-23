#!/bin/bash
# Runs once, automatically, on first boot of the SonarQube EC2 instance.
# Formats/mounts the dedicated data EBS volume, tunes the kernel for
# SonarQube's embedded Elasticsearch, and brings up SonarQube + Postgres
# via Docker Compose. No `aws configure` here either — this instance's
# IAM role (terraform/sonarqube.tf) is scoped to SSM session access only;
# SonarQube itself makes no AWS API calls.
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

dnf update -y
dnf install -y docker

systemctl enable docker
systemctl start docker

# Docker Compose v2 plugin (not reliably packaged in the AL2023 repos).
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
  "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-x86_64"
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# --- Find and mount the dedicated data volume ---
# t3 instances are Nitro-based, so the second EBS volume typically shows
# up as /dev/nvme1n1 rather than the /dev/xvdf requested at attach time —
# check both rather than assuming one.
DEVICE=""
for candidate in /dev/nvme1n1 /dev/xvdf; do
  if [ -e "$candidate" ]; then
    DEVICE="$candidate"
    break
  fi
done
if [ -z "$DEVICE" ]; then
  echo "FATAL: could not find the attached data volume (checked nvme1n1, xvdf)" >&2
  exit 1
fi

if ! blkid "$DEVICE" >/dev/null 2>&1; then
  mkfs -t ext4 "$DEVICE"
fi
mkdir -p /data
grep -q "$DEVICE" /etc/fstab || echo "$DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
mkdir -p /data/sonarqube/data /data/sonarqube/logs /data/sonarqube/extensions /data/postgres

# --- Kernel tuning SonarQube's bundled Elasticsearch requires ---
cat >/etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system

cat >/etc/security/limits.d/99-sonarqube.conf <<'EOF'
*       soft    nofile  131072
*       hard    nofile  131072
*       soft    nproc   8192
*       hard    nproc   8192
EOF

# --- docker-compose.yml ---
mkdir -p /opt/sonarqube
cat >/opt/sonarqube/docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: "${sonar_db_password}"
      POSTGRES_DB: sonarqube
    volumes:
      - /data/postgres:/var/lib/postgresql/data

  sonarqube:
    image: sonarqube:10.6.0-community
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://postgres:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: "${sonar_db_password}"
    ports:
      - "9000:9000"
    volumes:
      - /data/sonarqube/data:/opt/sonarqube/data
      - /data/sonarqube/logs:/opt/sonarqube/logs
      - /data/sonarqube/extensions:/opt/sonarqube/extensions
    ulimits:
      nofile:
        soft: 131072
        hard: 131072
      nproc: 8192
EOF

cd /opt/sonarqube
docker compose up -d

echo "user-data bootstrap complete" > /var/log/user-data-complete.log
