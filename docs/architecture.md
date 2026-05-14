# NATSLab — Architecture

Finished-state design of the lab. Companion docs: [plan.md](plan.md) (implementation plan) and [runbook.md](runbook.md) (operator procedures).

## 1. Purpose

A four-node NATS.io cluster plus two NATS clients deployed into Azure resource group `RG-NatsLab`, used for testing NATS features (clustering, TLS, JetStream, leaf nodes, etc.). The lab fronts its TLS listener with an Azure Standard Load Balancer at `nats.lab.imav8n.com:4222`. A pre-existing PFX certificate in Azure Key Vault (`kv-natslab` / `natslab-tls`) is the TLS identity for the cluster.

## 2. Goals & Non-Goals

**Goals**
- Provisioning is deterministic and idempotent.
- Software install, config rendering, and service lifecycle are **separate** from Azure resource provisioning.
- Day-2 changes (NATS version bump, cluster config tweak, TLS rotation) do not require redeploying VMs.
- A single existing Linux VM (`bphost`) is the control plane for all configuration tasks.

**Non-Goals**
- High availability across regions or zones.
- Hardened production security posture. The NSG intentionally exposes 4222/6222/8222/22 to the internet to make the lab reachable from anywhere.
- Container/Kubernetes-based NATS. NATS runs as a native `systemd` unit.

## 3. Two-Layer Model

The previous design used Custom Script Extensions to install and configure NATS during VM provisioning. That mixed two concerns that change at different rates — infrastructure (rarely) and software config (often) — and produced an unreliable, hard-to-debug single shell string. The new design splits them:

| Layer            | Tool                              | Owns                                                                          | Lifecycle             |
| ---------------- | --------------------------------- | ----------------------------------------------------------------------------- | --------------------- |
| **Infrastructure** | Bicep (`infra/NATSDeploy.bicep`) | VNet, subnet, NSG, LB, public IPs, DNS A record, NICs, VMs, system-assigned MSIs | Changes per redesign  |
| **Configuration**  | Ansible (`ansible/`)             | Package install, cert distribution, `nats.conf`, systemd unit, NATS CLI, smoke test | Changes per day-2 op |

A bash wrapper (`scripts/deploy.sh`) glues them together: it runs `az deployment`, reads the Bicep outputs, builds a JSON context, pipes it through a small Jinja2 renderer (`scripts/render-inventory.py`) to produce `ansible/inventory.yml`, then invokes `ansible-playbook`. Either layer can be re-run independently.

## 4. Components

```
                                  +--------------------+
                                  |  bphost (control)  |
                                  |  - az CLI          |
                                  |  - Ansible         |
                                  |  - python3-jinja2  |
                                  |  - this repo       |
                                  +---------+----------+
                                            |  SSH + Azure CLI
                                            v
+--------------------+        +-------------+-------------+
|  Azure Key Vault   | <----- |  RG-NatsLab               |
|  kv-natslab        |   az   |                           |
|  secret: natslab-tls|       |  ┌─────────────────────┐ |
+--------------------+        |  │ Standard LB         │ |  Public IP, DNS A: nats.lab.imav8n.com
                              |  │   :4222 -> backend  │ |  <----- Internet :4222 (TLS)
                              |  └─────────┬───────────┘ |
                              |            │             |
                              |  ┌─────────┴───────────┐ |
                              |  │ natslab-vnet        │ |
                              |  │ 10.0.0.0/16         │ |
                              |  │ subnet 10.0.1.0/24  │ |
                              |  │                     │ |
                              |  │  nats-node0..3      │ |  per-VM public IPs (SSH only)
                              |  │   :4222 :6222 :8222 │ |
                              |  │                     │ |
                              |  │  nats-client0       │ |  public IP (SSH + smoke test)
                              |  │  nats-client1       │ |  private only (bphost must have L3 to this subnet)
                              |  └─────────────────────┘ |
                              +---------------------------+
```

## 5. What Bicep Owns

Defined in [infra/NATSDeploy.bicep](../infra/NATSDeploy.bicep). The two `Microsoft.Compute/virtualMachines/extensions` resources from the prior revision are gone — VMs come up as **blank Ubuntu 22.04** with only an authorized SSH key.

- `natslab-vnet` (10.0.0.0/16) and `natslab-subnet` (10.0.1.0/24)
- `natslab-nsg` allowing 22, 4222, 6222, 8222 from internet (lab posture)
- `natslab-lb` Standard SKU with:
  - frontend → `natslab-lb-pip` (static public IP)
  - backend → all four NATS NICs
  - TCP probe on 4222, rule 4222 → 4222
- DNS zone `lab.imav8n.com` (existing) + A record `nats` → LB public IP
- 4× `nats-node{0..3}` VMs, each with system-assigned managed identity and its own static Standard public IP (named `nats-node{i}-pip`)
- 2× `nats-client{0..1}` VMs; `client0` has a static Standard public IP, `client1` is private only

**Bicep outputs consumed by `scripts/deploy.sh`**:

| Output                  | Used as                                                |
| ----------------------- | ------------------------------------------------------ |
| `adminUsername`         | `ansible_user`                                         |
| `keyVaultName`          | KV name for `nats-cert` role                           |
| `pfxSecretName`         | secret name for `nats-cert` role                       |
| `natsPublicFqdn`        | `nats_public_fqdn` (used by smoke test + future clients) |
| `loadBalancerPublicIp`  | reported (informational)                               |
| `natsNodeNames[]`       | inventory hostnames in `nats_servers`                  |
| `natsNodePublicIps[]`   | `ansible_host` per NATS node                           |
| `natsNodePrivateIps[]`  | `private_ip` host var (cluster routes / debugging)     |
| `clientNames[]`         | inventory hostnames in `nats_clients`                  |
| `clientPrivateIps[]`    | `private_ip` host var; also `ansible_host` for client1 |
| `client0PublicIp`       | `ansible_host` for client0                             |

## 6. What Ansible Owns

Layout under `ansible/`:

```
ansible/
├── ansible.cfg
├── inventory.yml             # generated by scripts/deploy.sh; do not edit
├── inventory.yml.j2          # Jinja2 template fed bicep outputs
├── group_vars/
│   ├── all.yml               # versions, ports, paths, cert_stage_dir
│   ├── nats_servers.yml      # nats_service_user
│   └── nats_clients.yml      # smoketest subject/payload
├── playbooks/
│   ├── site.yml              # end-to-end (servers + clients + smoketest)
│   ├── servers.yml
│   ├── clients.yml
│   └── smoketest.yml
└── roles/
    ├── common/               # apt update, base packages
    ├── nats-cert/            # runs on bphost; fetches PFX, splits to PEMs
    ├── nats-server/          # installs nats-server, renders nats.conf + unit
    └── nats-client/          # installs nats CLI
```

### Variables (in `ansible/group_vars/all.yml`)

| Variable               | Default                        | Notes                                              |
| ---------------------- | ------------------------------ | -------------------------------------------------- |
| `nats_server_version`  | `2.10.22`                      | GitHub release tag (without leading `v`)            |
| `nats_cli_version`     | `0.1.5`                        | natscli release tag                                |
| `nats_install_bin`     | `/usr/local/bin/nats-server`   | full path to binary                                |
| `nats_cli_install_bin` | `/usr/local/bin/nats`          | full path to CLI                                   |
| `nats_config_dir`      | `/etc/nats`                    | created by `common` role                           |
| `nats_cert_dir`        | `/etc/nats/certs`              | created by `nats-server` role                      |
| `nats_client_port`     | `4222`                         |                                                    |
| `nats_cluster_port`    | `6222`                         |                                                    |
| `nats_monitor_port`    | `8222`                         | HTTP monitoring                                    |
| `nats_cluster_name`    | `lab`                          |                                                    |
| `cert_stage_dir`       | `/tmp/natslab-cert`            | PEMs live here on bphost between plays              |
| `nats_service_user`    | `nats` (in `nats_servers.yml`) | systemd `User=` for nats-server (system user created by the role) |
| `nats_service_group`   | `nats` (in `nats_servers.yml`) | system group created by the role                   |

### `nats-cert` role (runs on bphost via `connection: local`)

1. Ensures `cert_stage_dir` exists with mode `0700`.
2. `az keyvault secret download` → `cert.pfx` (base64-decoded binary).
3. `openssl pkcs12` → `cert.pem` (cert only) and `key.pem` (key only), passwordless PFX assumed.
4. Removes `cert.pfx`, leaving the PEMs for the `nats-server` role to read.

This **eliminates the need for per-VM `az login --identity`** and avoids granting Key Vault access to each VM's MSI.

### `nats-server` role (runs on each `nats_servers` host as root)

1. Creates the `nats` system group and `nats` system user (no shell, no home dir).
2. Ensures `nats_config_dir` and `nats_cert_dir` exist and are owned by `nats:nats` (mode 0750).
3. `copy:`s `cert.pem` (0644) and `key.pem` (0600) from the controller's `cert_stage_dir` to `nats_cert_dir`, both owned by `nats:nats`.
4. Downloads the pinned `nats-server` release zip if the running binary's version differs.
5. Installs the binary at `nats_install_bin`.
6. Renders `/etc/nats/nats.conf` from `nats.conf.j2`, which iterates `groups['nats_servers']` and emits one cluster route per node using `hostvars[host].nats_private_ip` (populated from the Bicep output `natsNodePrivateIps[]`).
7. Renders `/etc/systemd/system/nats-server.service` with `User={{ nats_service_user }}` (default `nats`).
8. `systemctl daemon-reload` + `enable` + `start`. A `restart nats-server` handler fires on any cert / config / unit / binary change.

### `nats-client` role (runs on each `nats_clients` host as root)

1. Downloads pinned `natscli` release zip if version differs.
2. Installs `nats` at `nats_cli_install_bin`.

### `smoketest.yml` (runs on `nats_clients[0]`)

From client0, subscribes to `lab.test`, publishes `hello`, asserts receipt within 2 s against `tls://{{ nats_public_fqdn }}:{{ nats_client_port }}` — the load-balanced public endpoint. Replaces the old CSE smoke test with an idempotent, fail-loud task.

## 7. Deploy Flow

```
 user @ bphost                                                                      Azure
 │
 ├── git pull
 ├── ./scripts/deploy.sh ─────────► az deployment group create ────────────────► RG-NatsLab
 │                                                                  └──► resources updated
 │                                  ◄──── az deployment group show (outputs) ─────────┘
 │
 ├── jq builds context JSON (admin, ssh key, fqdn, kv, pfx, servers[], clients[])
 ├── scripts/render-inventory.py applies inventory.yml.j2 → ansible/inventory.yml
 │
 ├── ansible-playbook site.yml ─── plays:
 │      ├── localhost                  → nats-cert: fetch PFX from KV, split to PEMs
 │      ├── nats_servers               → common + nats-server: install, config, start
 │      ├── nats_clients               → common + nats-client: install CLI
 │      └── nats_clients[0]            → pub/sub smoke test
 │
 └── ✅
```

Re-running `deploy.sh` is idempotent at both layers — Bicep is a declarative `az deployment`, and every Ansible task uses idempotent modules (`apt`, `template`, `copy`, `systemd`, version-gated `get_url`).

## 8. Trust & Security Boundaries

- **Key Vault** is the source of truth for the TLS material. Only `bphost`'s identity needs `Get` on the secret. The four NATS VMs never call Azure APIs at runtime.
- **SSH** is the only credential plane to the VMs. Public-key auth only (`disablePasswordAuthentication: true`).
- **TLS** terminates on each NATS server (the LB is L4 pass-through). Cluster traffic on 6222 is also TLS-wrapped using the same cert.
- **NSG** is intentionally permissive (lab). Production would scope SSH to a management CIDR and remove the 6222/8222 internet rule (cluster + monitoring should never be public).
- **PEMs on bphost** live in `/tmp/natslab-cert/` between plays. The `nats-cert` role currently removes the PFX after extracting but leaves the PEMs in place so subsequent `--skip-bicep` re-runs of the server play can distribute without re-fetching. To force re-fetch, `rm -rf /tmp/natslab-cert` before re-running.

## 9. Network Reachability from bphost

The inventory uses **public IPs** for all NATS nodes and `client0`, but **private IP** for `client1`. This means `bphost` must have layer-3 connectivity to `10.0.1.0/24` to reach `client1`. Options:

- **Same VNet** — deploy `bphost` into `natslab-vnet`. Simplest.
- **VNet peering** — peer `bphost`'s VNet with `natslab-vnet`. Production-realistic.
- **Add a `ProxyJump`** — extend `inventory.yml.j2` so `client1` proxies through `client0`. No infra change required, but adds a hop and a dependency.

If `bphost` does not yet have private reachability, run `scripts/deploy.sh -- --limit nats_servers,nats_clients[0]` to skip `client1` for now.

## 10. Alternatives Considered

| Option                       | Why not (here)                                                            |
| ---------------------------- | ------------------------------------------------------------------------- |
| Stay on CSE                  | Brittle single-shell-string failures; no day-2 model.                      |
| `cloud-init` via `customData`| Better than CSE, but still bakes config into the deploy; no push-mode ops. |
| Packer-baked image           | Best for production; slower iteration than what a lab needs.               |
| Azure Automation DSC         | Windows-leaning, overkill for 6 VMs.                                       |

A future iteration can combine **Packer** (golden image with `nats-server` pre-installed) with **Ansible** (cert + config + cluster topology). The Ansible roles are already structured to be near-no-ops on a pre-baked binary.

## 11. Decisions & Trade-offs

- **Per-VM public IPs on NATS nodes** — adds 4 public IPs (cost) but removes the need for VNet peering between bphost and the lab VNet for management of the servers. The NSG already allowed SSH from the internet, so blast radius is unchanged.
- **Cert fetched once on bphost, distributed via Ansible** — single point of cert handling, no per-VM Azure CLI install, no KV access policy per MSI. Trade-off: the PEMs briefly exist on bphost in `/tmp/natslab-cert/`.
- **Cluster routes use private IPs from Bicep outputs** — `nats.conf.j2` reads each peer's `nats_private_ip` host var rather than relying on Azure-provided VNet DNS to resolve `nats-node{0..3}`. More resilient to DNS edge cases.
- **NATS service runs as a dedicated `nats` system user** — the `nats-server` role creates the user/group and chowns `/etc/nats` and `/etc/nats/certs` accordingly. Private key is 0600, cert is 0644, all owned by `nats:nats`.
- **Versions are pinned** — `nats_server_version` and `nats_cli_version` are explicit semver strings, not `latest`. Pins avoid unexpected drift across re-runs.

## 12. Files in This Repo

```
NATSLab/
├── Spec.md                          # top-level project intro / index
├── infra/
│   └── NATSDeploy.bicep             # infrastructure (no extensions)
├── infra.parameters.example.json    # template — copy to infra.parameters.json
├── docs/
│   ├── architecture.md              # this file
│   ├── plan.md                      # phased implementation plan
│   └── runbook.md                   # operational walkthrough
├── scripts/
│   ├── bootstrap-bphost.sh          # one-time setup of bphost
│   ├── render-inventory.py          # Jinja2 renderer used by deploy.sh
│   └── deploy.sh                    # run on bphost
└── ansible/
    ├── ansible.cfg
    ├── inventory.yml.j2
    ├── group_vars/{all,nats_servers,nats_clients}.yml
    ├── playbooks/{site,servers,clients,smoketest}.yml
    └── roles/{common,nats-cert,nats-server,nats-client}/
```

See [runbook.md](runbook.md) for the step-by-step deploy walkthrough and day-2 operations.
