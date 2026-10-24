#!/usr/bin/env bash
# Run on a fresh Ubuntu 22.04/24.04 EC2 (t3.medium+, 20GB disk) as a sudo user.
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg unzip git openjdk-17-jre

# --- Jenkins (official apt repo) ---
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null
sudo apt-get update -y && sudo apt-get install -y jenkins

# --- Docker ---
sudo apt-get install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker "$USER"

# --- AWS CLI v2 ---
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update

# --- kubectl (latest stable) ---
KVER="$(curl -Ls https://dl.k8s.io/release/stable.txt)"
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# --- eksctl ---
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

sudo systemctl enable --now docker jenkins
sudo systemctl restart jenkins

echo "Jenkins initial admin password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
echo "Open: http://<EC2-PUBLIC-IP>:8080"
