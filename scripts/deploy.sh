#!/usr/bin/env bash
# Deploy the NATS lab: Bicep first, then Ansible.
# Run on bphost from the repo root, or via ./scripts/deploy.sh from anywhere.
set -euo pipefail

# ---------- config (override via env) ----------
RESOURCE_GROUP="${RESOURCE_GROUP:-RG-NatsLab}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-natslab-$(date +%Y%m%d-%H%M%S)}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/natslab_id}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BICEP_FILE="${BICEP_FILE:-$REPO_ROOT/infra/NATSDeploy.bicep}"
PARAMS_FILE="${PARAMS_FILE:-$REPO_ROOT/infra.parameters.json}"
ANSIBLE_DIR="$REPO_ROOT/ansible"
INVENTORY_TMPL="$ANSIBLE_DIR/inventory.yml.j2"
INVENTORY_OUT="$ANSIBLE_DIR/inventory.yml"
PLAYBOOK="${PLAYBOOK:-$ANSIBLE_DIR/playbooks/site.yml}"
RENDERER="$SCRIPT_DIR/render-inventory.py"

# ---------- flags ----------
INVENTORY_ONLY=0
SKIP_BICEP=0
ANSIBLE_ARGS=()

usage() {
  cat <<EOF
Usage: $0 [--inventory-only] [--skip-bicep] [-- <ansible-playbook args>]

  --inventory-only    Re-read existing deployment outputs and regenerate inventory.yml only.
  --skip-bicep        Skip the Bicep deploy; just re-read outputs and run Ansible.
  -h, --help          Show this message.

Environment overrides:
  RESOURCE_GROUP    (default: RG-NatsLab)
  DEPLOYMENT_NAME   (default: natslab-<timestamp>)
  BICEP_FILE        (default: <repo>/infra/NATSDeploy.bicep)
  PARAMS_FILE       (default: <repo>/infra.parameters.json)
  PLAYBOOK          (default: <repo>/ansible/playbooks/site.yml)
  SSH_PRIVATE_KEY   (default: \$HOME/.ssh/natslab_id)

Args after '--' are forwarded to ansible-playbook, e.g.:
  $0 -- --check
  $0 -- --tags config --limit nats-node0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-only) INVENTORY_ONLY=1; shift ;;
    --skip-bicep)     SKIP_BICEP=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    --)               shift; ANSIBLE_ARGS+=("$@"); break ;;
    *)                ANSIBLE_ARGS+=("$1"); shift ;;
  esac
done

# ---------- preflight ----------
command -v az               >/dev/null || { echo "az CLI not found";            exit 1; }
command -v jq               >/dev/null || { echo "jq not found";                exit 1; }
command -v ansible-playbook >/dev/null || { echo "ansible-playbook not found"; exit 1; }
command -v python3          >/dev/null || { echo "python3 not found";           exit 1; }
python3 -c "import jinja2" 2>/dev/null  || { echo "python3-jinja2 not installed (run scripts/bootstrap-bphost.sh)"; exit 1; }

if ! az account show --output none 2>/dev/null; then
  echo "Azure CLI not authenticated. Run 'az login' or 'az login --identity' first."
  exit 1
fi

# ---------- 1. Bicep ----------
if [[ "$SKIP_BICEP" -eq 0 && "$INVENTORY_ONLY" -eq 0 ]]; then
  [[ -f "$PARAMS_FILE" ]] || { echo "Missing $PARAMS_FILE — copy from infra.parameters.example.json"; exit 1; }
  echo "[1/3] Deploying Bicep ($DEPLOYMENT_NAME) to $RESOURCE_GROUP …"
  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --name           "$DEPLOYMENT_NAME" \
    --template-file  "$BICEP_FILE" \
    --parameters    @"$PARAMS_FILE" \
    --output none
fi

# ---------- 2. Read outputs and render inventory ----------
echo "[2/3] Reading deployment outputs and rendering inventory …"

# Resolve a working deployment name if the timestamp one doesn't exist
# (e.g., --skip-bicep / --inventory-only between runs).
if ! az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --output none 2>/dev/null; then
  DEPLOYMENT_NAME=$(az deployment group list \
    -g "$RESOURCE_GROUP" \
    --query "sort_by([?contains(name, 'natslab-')], &properties.timestamp)[-1].name" \
    -o tsv)
  echo "    using latest deployment: $DEPLOYMENT_NAME"
fi

OUTPUTS=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.outputs)

ADMIN_USERNAME=$(echo "$OUTPUTS" | jq -r '.adminUsername.value')
CLIENT0_PUBLIC_IP=$(echo "$OUTPUTS" | jq -r '.client0PublicIp.value')

CONTEXT_FILE=$(mktemp)
trap 'rm -f "$CONTEXT_FILE"' EXIT

echo "$OUTPUTS" | jq \
  --arg admin    "$ADMIN_USERNAME" \
  --arg ssh_key  "$SSH_PRIVATE_KEY" \
  --arg cli0_pip "$CLIENT0_PUBLIC_IP" \
  '{
    admin_username:   $admin,
    ssh_private_key:  $ssh_key,
    nats_public_fqdn: .natsPublicFqdn.value,
    key_vault_name:   .keyVaultName.value,
    pfx_secret_name:  .pfxSecretName.value,
    nats_servers: (
      [ .natsNodeNames.value, .natsNodePublicIps.value, .natsNodePrivateIps.value ]
      | transpose | to_entries
      | map({
          name:       .value[0],
          public_ip:  .value[1],
          private_ip: .value[2],
          index:      .key
        })
    ),
    nats_clients: (
      [ .clientNames.value, .clientPrivateIps.value ]
      | transpose | to_entries
      | map({
          name:       .value[0],
          public_ip:  (if .key == 0 then $cli0_pip else null end),
          private_ip: .value[1],
          index:      .key
        })
    )
  }' > "$CONTEXT_FILE"

python3 "$RENDERER" "$CONTEXT_FILE" "$INVENTORY_TMPL" "$INVENTORY_OUT"
echo "    wrote $INVENTORY_OUT"

if [[ "$INVENTORY_ONLY" -eq 1 ]]; then
  echo "Done (inventory only)."
  exit 0
fi

# ---------- 3. Ansible ----------
echo "[3/3] Running ansible-playbook $PLAYBOOK …"
cd "$ANSIBLE_DIR"
ansible-playbook -i "$INVENTORY_OUT" "$PLAYBOOK" "${ANSIBLE_ARGS[@]}"
