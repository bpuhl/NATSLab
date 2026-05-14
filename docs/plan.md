# NATSLab — Option B Implementation Plan

Split the current monolithic Bicep deployment into two layers:

- **Bicep** provisions only Azure resources (network, LB, DNS, VMs).
- **Ansible**, driven from the existing `bphost` VM, installs and configures NATS server and client software.

The two layers communicate via Bicep deployment outputs that are rendered into an Ansible inventory.

---

## Assumptions (will be documented in architecture.md)

1. `bphost` is a Linux VM with outbound internet, Azure CLI, and an SSH client. We'll install Ansible and required collections on it.
2. `bphost` has an Azure identity (system-assigned MSI or `az login` user) with:
   - `Reader` + `Network Contributor` on `RG-NatsLab` (to read deployment outputs)
   - `get` on the PFX secret in `kv-natslab`
3. The SSH private key matching `adminSshPublicKey` is available on `bphost` at `~/.ssh/natslab_id` (we'll document key placement, not provision it).
4. NATS nodes need to be SSH-reachable from `bphost`. Since the original NSG already permits SSH from the internet, we'll **add a per-VM public IP to each NATS node** for management. The existing internal-DNS clustering (`nats-node0..3:6222`) still works inside the VNet.
5. The TLS certificate is pulled from Key Vault **once on `bphost`** (where MSI/KV permissions live), converted to PEM, and distributed to each NATS server via Ansible. This removes the need for `az` CLI + MSI permissions on every NATS VM.
6. NATS server version is pinned in `group_vars/all.yml` (default: latest stable; overridable per environment).

---

## Target repo layout

```
NATSLab/
├── README.md
├── docs/
│   ├── plan.md                      # this file
│   ├── architecture.md              # design doc with diagram + rationale
│   └── runbook.md                   # operator steps: bootstrap, deploy, recover
├── infra/
│   └── NATSDeploy.bicep             # infra only — no CustomScript extensions
├── scripts/
│   ├── bootstrap-bphost.sh          # one-time setup on bphost (ansible + collections)
│   └── deploy.sh                    # az deployment → render inventory → ansible-playbook
└── ansible/
    ├── ansible.cfg
    ├── inventory.yml.j2             # template rendered from bicep outputs
    ├── group_vars/
    │   ├── all.yml                  # nats version, FQDN, KV settings
    │   ├── nats_servers.yml
    │   └── nats_clients.yml
    ├── playbooks/
    │   ├── site.yml                 # full deploy (servers + clients + smoketest)
    │   ├── servers.yml
    │   ├── clients.yml
    │   └── smoketest.yml
    └── roles/
        ├── common/                  # apt update, base packages, hostname
        ├── nats-cert/               # distributes PEM cert/key fetched on bphost
        ├── nats-server/             # binary + nats.conf + systemd unit
        └── nats-client/             # nats CLI binary
```

---

## Phase 1 — Refactor the Bicep (infra only)

**File:** [infra/NATSDeploy.bicep](infra/NATSDeploy.bicep) (moved from repo root)

1. **Remove** both `Microsoft.Compute/virtualMachines/extensions` blocks (`natsExtension`, `clientExtension`).
2. **Add** a public IP per NATS node and attach it to each NATS NIC's ipconfig.
3. **Add** outputs consumed by the deploy script:
   - `natsNodeNames` — array of computer names
   - `natsNodePublicIps` — array
   - `natsNodePrivateIps` — array (needed for cluster route fallback / debugging)
   - `clientNames` — array
   - `clientPublicIps` — array (only client0 has one; others null)
   - `clientPrivateIps` — array
   - `natsPublicFqdn`, `keyVaultName`, `pfxSecretName`, `adminUsername`
4. **Keep** everything else: VNet, NSG, LB, DNS A record, MSI on NATS VMs (still useful for future use), Ubuntu image, SSH key, sizes.

Net diff: ~120 lines removed, ~40 lines added, infra is now declarative-only and deploys in ~3 minutes with no script execution.

---

## Phase 2 — Ansible scaffolding on `bphost`

**Files:** [ansible/ansible.cfg](ansible/ansible.cfg), [ansible/inventory.yml.j2](ansible/inventory.yml.j2), [ansible/group_vars/](ansible/group_vars/)

1. `ansible.cfg`: set `host_key_checking = False` (lab), `inventory = ./inventory.yml`, `roles_path = ./roles`, `forks = 10`, `stdout_callback = yaml`.
2. `inventory.yml.j2`: Jinja2 template rendered by `deploy.sh` from Bicep outputs. Two groups: `nats_servers` and `nats_clients`. Each host gets `ansible_host` (public IP), `private_ip`, and `nats_node_index` vars.
3. `group_vars/all.yml`: NATS server version, NATS CLI version, FQDN, KV name, PFX secret name, paths (`/etc/nats`, `/etc/nats/certs`), admin user.

**Bootstrap script** [scripts/bootstrap-bphost.sh](scripts/bootstrap-bphost.sh) (one-time, idempotent):
- `apt-get install -y ansible azure-cli jq openssl`
- `ansible-galaxy collection install community.general ansible.posix`

---

## Phase 3 — Ansible roles

### `roles/common`
- Update apt cache, install `curl`, `unzip`, `jq`, `ca-certificates`.
- Set hostname to match Azure computer name (idempotent).

### `roles/nats-cert` (servers only)
Runs **once on `bphost` localhost** at the top of the play, then distributes to each server:
1. `delegate_to: localhost`, `run_once: true` — fetch PFX with `az keyvault secret download` to a temp dir on `bphost`.
2. `openssl pkcs12` → split into `cert.pem` and `key.pem` on `bphost`.
3. `copy:` cert and key to each NATS server's `/etc/nats/certs/` with `mode: 0644` / `0600`, owner `root`.
4. Clean up temp files on `bphost`.

### `roles/nats-server`
1. Download `nats-server` Linux amd64 zip from GitHub releases for the pinned version.
2. Unzip to `/usr/local/bin/nats-server`, set executable.
3. Template `/etc/nats/nats.conf` with cluster routes resolving to `nats-node0..3:6222` (Azure-provided internal DNS).
4. Template `/etc/systemd/system/nats-server.service`.
5. `systemctl daemon-reload`, enable + start, with a handler that restarts on config or cert change.

### `roles/nats-client`
1. Download `natscli` Linux amd64 zip, install `nats` to `/usr/local/bin/nats`.
2. (No service; just the CLI.)

### Smoketest playbook `playbooks/smoketest.yml`
- From `client0`, subscribe to `lab.test` in the background, publish `hello`, assert receipt — same logic as the current CSE but as an idempotent task with proper error reporting.

---

## Phase 4 — Deploy orchestration

**File:** [scripts/deploy.sh](scripts/deploy.sh) (run on `bphost`)

```
1. az group create --name RG-NatsLab --location <loc>     # idempotent
2. az deployment group create --resource-group RG-NatsLab \
       --template-file ../infra/NATSDeploy.bicep \
       --parameters adminUsername=... adminSshPublicKey=@~/.ssh/natslab_id.pub \
       --query 'properties.outputs' -o json > /tmp/natslab-outputs.json
3. Render ansible/inventory.yml from inventory.yml.j2 using jq + envsubst (or a tiny python helper)
4. ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml
```

Flags: `--skip-infra`, `--skip-config`, `--smoketest-only` for partial runs (e.g., software-only redeploys).

---

## Phase 5 — Documentation

### [docs/architecture.md](docs/architecture.md)
- Component diagram (ASCII): bphost → Azure ARM, bphost → SSH → NATS/client VMs, NATS VMs ↔ Key Vault (not used after Option B), NATS VMs ↔ LB ↔ Internet.
- Data-flow walkthrough of a deploy.
- "Why Ansible over cloud-init / CSE / Packer" — short rationale section.
- Security notes: SSH exposure, NSG, MSI scope, cert handling.

### [docs/runbook.md](docs/runbook.md)
- Prerequisites checklist (bphost MSI roles, KV access, SSH key on bphost).
- First-time deploy steps.
- Day-2 operations: rotate cert, upgrade NATS version, add a node, drain a node, reset cluster.
- Troubleshooting: cluster won't form, cert mismatch, smoketest fails.

### [README.md](README.md) (top-level, brief)
- One-paragraph summary, link to `docs/architecture.md` and `docs/runbook.md`.

---

## Phase 6 — Verification

1. `az bicep build` succeeds on the new template.
2. `ansible-playbook --syntax-check` clean for all playbooks.
3. `ansible-lint` clean (best-effort).
4. Full end-to-end on a throwaway `RG-NatsLab-test` from `bphost`: deploy infra → run playbooks → smoketest publishes/receives on `nats.lab.imav8n.com:4222`.
5. Re-run `deploy.sh` → second run is a no-op (idempotency check).

---

## Out of scope for this change

- Granting `bphost`'s MSI the required RBAC and KV access policy — listed as a prereq in the runbook.
- Packer-baked golden images (the Option C add-on; can layer on later without touching this design).
- Private DNS zone for NATS nodes — relying on Azure-provided VNet DNS for `nats-node{0..3}` short-name resolution.
- JetStream / leafnode / auth setup — current lab is anonymous TLS only; placeholders left in `nats.conf.j2`.
