#!/usr/bin/env bash
# One-time setup for bphost (the Ansible control machine).
# Idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  SUDO=sudo
else
  SUDO=
fi

echo "[bootstrap] Updating apt cache"
$SUDO apt-get update -y

echo "[bootstrap] Installing base packages"
$SUDO apt-get install -y \
  ansible \
  jq \
  openssl \
  python3-pip \
  python3-jinja2 \
  curl \
  ca-certificates \
  apt-transport-https \
  lsb-release \
  gnupg

if ! command -v az >/dev/null 2>&1; then
  echo "[bootstrap] Installing Azure CLI"
  curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash
fi

echo "[bootstrap] Installing Ansible collections"
ansible-galaxy collection install -U community.general ansible.posix

echo "[bootstrap] Done. Next steps:"
echo "  1. az login   (or rely on the VM's managed identity: az login --identity)"
echo "  2. Ensure ~/.ssh/natslab_id and natslab_id.pub exist for the lab admin user"
echo "  3. ./scripts/deploy.sh"
