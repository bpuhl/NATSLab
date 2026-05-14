# NATSLab — Runbook

Operational walkthrough for deploying and maintaining the NATS lab. Companion to [Spec.md](../Spec.md).

## 1. Prerequisites

### On `bphost` (the Ansible control machine)

Run the one-time bootstrap script (idempotent):

```bash
git clone <this-repo-url> ~/NATSLab
cd ~/NATSLab
sudo ./scripts/bootstrap-bphost.sh
```

The script installs `ansible`, the Azure CLI, `jq`, `openssl`, and the required Ansible collections (`community.general`, `ansible.posix`).

Verify:

```bash
az --version
ansible --version
```

### Azure-side prereqs (one-time)

| Resource | Required state |
| --- | --- |
| Subscription | `bphost` identity has Contributor (or scoped Owner) on `RG-NatsLab`. |
| Resource group | `RG-NatsLab` exists. |
| DNS zone | `lab.imav8n.com` already exists in `RG-NatsLab` (Bicep declares it as `existing`). |
| Key Vault | `kv-natslab` exists; secret `natslab-tls` holds the PFX (no password). |
| Key Vault access | `bphost`'s identity has `Get` on secrets in `kv-natslab`. |

Grant Key Vault access to `bphost`'s system-assigned MSI (run from a workstation that already has Owner on the KV):

```bash
BPHOST_PRINCIPAL=$(az vm show -n bphost -g <bphost-rg> --query identity.principalId -o tsv)
az role assignment create \
  --assignee "$BPHOST_PRINCIPAL" \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n kv-natslab --query id -o tsv)
```

(Use access policies instead of RBAC if `kv-natslab` is in the legacy permission model.)

### SSH key

The same private key used to SSH to `bphost` must have its public half passed to Bicep as `adminSshPublicKey`. On bphost, that key needs to exist at the default location (e.g. `~/.ssh/id_ed25519`) or be configured in `~/.ssh/config`.

## 2. First-Time Setup

On bphost:

```bash
git clone <this-repo-url> ~/NATSLab
cd ~/NATSLab
cp infra.parameters.example.json infra.parameters.json
$EDITOR infra.parameters.json   # fill adminUsername + adminSshPublicKey
```

Sign in to Azure:

```bash
az login --identity   # uses bphost's MSI
# or
az login              # interactive device code
az account set --subscription <subscription-id>
```

## 3. Deploy

```bash
cd ~/NATSLab
./scripts/deploy.sh
```

What it does, in order:

1. `az deployment group create -g RG-NatsLab --template-file infra/NATSDeploy.bicep ...`
2. Reads the deployment outputs.
3. Generates `ansible/inventory.yml`.
4. Runs `ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml`.

The script forwards any extra args to `ansible-playbook`, so you can do:

```bash
./scripts/deploy.sh --check                # dry run
./scripts/deploy.sh --tags nats-server     # only the server role
./scripts/deploy.sh -l nats-node0          # only one host
```

## 4. Day-2 Operations

### Bump the NATS server version

Edit `ansible/group_vars/all.yml`:

```yaml
nats_server_version: "2.10.20"   # pin instead of "latest"
```

Then re-run only the config layer (no Bicep deploy):

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/servers.yml
```

The role detects the new version, downloads it, replaces `/usr/local/bin/nats-server`, and the `restart nats-server` handler restarts the unit. Use `--limit nats-node0` first if you want a canary.

### Change `nats.conf` (e.g. enable JetStream)

Edit `ansible/roles/nats-server/templates/nats.conf.j2`, then:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/servers.yml --tags config
```

(The template handler restarts on change.)

### Rotate the TLS certificate

1. Upload the new PFX to `kv-natslab` under the same secret name (or change `pfxSecretName` in `infra.parameters.json`).
2. Clear the staging dir on bphost: `rm -rf /tmp/natslab-cert`.
3. Re-run the servers playbook:

   ```bash
   ansible-playbook -i ansible/inventory.yml ansible/playbooks/servers.yml
   ```

The cert role re-fetches and the copy tasks notify the restart handler.

### Add a fifth NATS node

In `infra.parameters.json` bump `natsNodeCount` to 5, then:

```bash
./scripts/deploy.sh
```

Bicep provisions the new VM, the inventory regenerates with it, and `nats.conf` on all five nodes gets re-rendered with the new route list.

### Tear down

```bash
az group delete -n RG-NatsLab --yes --no-wait
```

(The DNS zone is declared `existing` and is not deleted by this.)

## 5. Troubleshooting

### Smoke test fails

```bash
ssh <admin>@<nats-client0-public-ip>
sudo journalctl -u nats-server --no-pager   # not running here, but useful pattern
nats sub lab.test --server tls://nats.lab.imav8n.com:4222
# in another window:
nats pub lab.test hi --server tls://nats.lab.imav8n.com:4222
```

### A NATS node is unhealthy

```bash
ssh <admin>@<nats-node0-public-ip>
sudo systemctl status nats-server
sudo journalctl -u nats-server -n 200 --no-pager
curl -s http://localhost:8222/varz | jq .   # monitoring endpoint
```

### Cert fetch fails on bphost

```bash
az account show                                   # are you logged in?
az keyvault secret show -n natslab-tls --vault-name kv-natslab   # do you have Get?
```

### Re-render inventory only (no Bicep deploy)

If something is off in the inventory file:

```bash
./scripts/deploy.sh --inventory-only
```

(The script supports this flag; see `scripts/deploy.sh -h`.)

## 6. Files You Will Edit

| Frequency | File |
| --- | --- |
| Once | `infra.parameters.json` |
| Per server config change | `ansible/roles/nats-server/templates/nats.conf.j2` |
| Per version pin | `ansible/group_vars/all.yml` |
| Per topology change | `infra/NATSDeploy.bicep` (counts, sizes, SKUs) |

Everything in `ansible/inventory.yml` is generated — do not hand-edit.
