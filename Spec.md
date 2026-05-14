# NATSLab — Architecture & Design

## 1. Purpose

A four-node NATS.io cluster plus two NATS clients deployed into Azure resource group `RG-NatsLab`, used for testing NATS features (clustering, TLS, JetStream, leaf nodes). The lab fronts its TLS listener with an Azure Standard Load Balancer at `nats.lab.imav8n.com:4222`. A pre-existing PFX certificate in Azure Key Vault is the TLS identity for the cluster.

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

The previous design used a Custom Script Extension to install and configure NATS during VM provisioning. That mixed two concerns that change at different rates — infrastructure (rarely) and software config (often) — and produced an unreliable, hard-to-debug single shell string. The new design splits them:

| Layer            | Tool                   | Owns                                                                            | Lifecycle              |
| ---------------- | ---------------------- | ------------------------------------------------------------------------------- | ---------------------- |
| **Infrastructure** | Bicep ([infra/NATSDeploy.bicep](infra/NATSDeploy.bicep)) | VNet, subnet, NSG, LB, public IPs, DNS A record, NICs, VMs, system-assigned MSIs | Changes per redesign   |
| **Configuration**  | Ansible ([ansible/](ansible/))       | Package install, cert distribution, `nats.conf`, systemd unit, NATS CLI, smoke test | Changes per day-2 op   |

A thin bash wrapper (`scripts/deploy.sh`) glues them together: it runs `az deployment`, reads the Bicep outputs, renders an Ansible inventory, and invokes `ansible-playbook`. Either layer can be re-run independently.

## 4. Components

```
                                  +--------------------+
                                  |  bphost (control)  |
                                  |  - az CLI          |
                                  |  - Ansible         |
                                  |  - this repo       |
                                  +---------+----------+
                                            |  SSH + Azure CLI
                                            v
+--------------------+        +-------------+-------------+
|  Azure Key Vault   | <----- |  RG-NatsLab               |
|  kv-natslab        |   az   |                           |
|  secret: natslab-tls|       |  ┌─────────────────────┐ |
+--------------------+        |  │ Standard LB         │ |  Public IP (DNS A: nats.lab.imav8n.com)
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
                              |  │  nats-client1       │ |  private only (ProxyJump via client0)
                              |  └─────────────────────┘ |
                              +---------------------------+
```

## 5. What Bicep Owns

Defined in [infra/NATSDeploy.bicep](infra/NATSDeploy.bicep). No more `Microsoft.Compute/virtualMachines/extensions` resources — VMs come up as **blank Ubuntu 22.04** with only an authorized SSH key.

- `natslab-vnet` (10.0.0.0/16) and `natslab-subnet` (10.0.1.0/24)
- `natslab-nsg` allowing 22, 4222, 6222, 8222 from internet (lab posture)
- `natslab-lb` Standard SKU with:
  - frontend → `natslab-lb-pip` (static public IP)
  - backend → all four NATS NICs
  - TCP probe on 4222, rule 4222→4222
- DNS zone `lab.imav8n.com` (existing) + A record `nats` → LB public IP
- 4× `nats-node{0..3}` VMs, each with system-assigned managed identity and its own static Standard public IP
- 2× `nats-client{0..1}` VMs; `client0` has a static Standard public IP, `client1` is private only

**Bicep outputs** that drive the Ansible inventory:

| Output                         | Used by                                  |
| ------------------------------ | ---------------------------------------- |
| `natsNodeNames[]`              | inventory hostnames                      |
| `natsNodePublicIps[]`          | `ansible_host` for nats_servers          |
| `natsNodePrivateIps[]`         | cluster routes in `nats.conf`            |
| `clientNames[]`                | inventory hostnames                      |
| `client0PublicIp`              | `ansible_host` for client0 + ProxyJump  |
| `clientPrivateIps[]`           | `ansible_host` for client1               |
| `natsHostName`, `dnsZoneName`  | NATS URL for clients and smoke test     |
| `natsPublicFqdn`               | convenience output (`<host>.<zone>`)    |
| `keyVaultName`, `pfxSecretName` | cert fetch on bphost                   |
| `adminUsername`                | `ansible_user`                           |
| `loadBalancerPublicIp`         | reference / DNS verification             |

## 6. What Ansible Owns

Layout under `ansible/`:

```
ansible/
├── ansible.cfg
├── inventory.yml              <- generated by scripts/deploy.sh; do not edit
├── group_vars/all.yml         <- versions, ports, paths
├── playbooks/
│   ├── site.yml               <- end-to-end (servers + clients + smoketest)
│   ├── servers.yml            <- NATS servers only
│   ├── clients.yml            <- NATS clients only
│   └── smoketest.yml          <- pub/sub round trip
└── roles/
    ├── common/                <- apt cache, base packages
    ├── nats-cert/             <- runs on bphost; fetches PFX, splits to PEMs
    ├── nats-server/           <- installs nats-server, renders nats.conf + unit
    └── nats-client/           <- installs nats CLI
```

**`nats-cert` runs on the control node**, not on each NATS server. It:

1. Verifies `az` is authenticated.
2. `az keyvault secret download --vault-name <kv> --name <secret> --file cert.pfx`
3. `openssl pkcs12` → `cert.pem` and `key.pem` in `/tmp/natslab-cert/` (mode 0700).

The `nats-server` role then `copy:`s those PEMs to each node (`/etc/nats/certs/{cert,key}.pem`). This **eliminates the need for per-VM `az login --identity`** and avoids granting Key Vault access to each VM's MSI.

**`nats-server` role**:
- Creates a system user `nats`.
- Downloads the latest `nats-server` Linux release from GitHub.
- Renders `/etc/nats/nats.conf` from a Jinja template that iterates `groups['nats_servers']` and emits a route to each node's private IP on 6222.
- Renders `/etc/systemd/system/nats-server.service` (runs as `nats`, `Restart=on-failure`, `LimitNOFILE=65536`).
- `systemctl daemon-reload` + `enable` + `start`.

**`nats-client` role**:
- Downloads the latest `natscli` release.
- Installs the `nats` binary at `/usr/local/bin/nats`.

**`smoketest.yml`**: from `nats-client0`, subscribes to `lab.test`, publishes `hello`, asserts receipt within 2 s. This replaces the old CSE smoke test.

## 7. Deploy Flow

```
 user @ bphost                                                                      Azure
 │
 ├── git pull                                                                          │
 ├── ./scripts/deploy.sh ────────► az deployment group create ─────────────────────► RG-NatsLab
 │                                                                  └──► resources updated
 │                                  ◄──── az deployment group show (outputs) ─────────┘
 │
 ├── render ansible/inventory.yml from outputs
 │
 ├── ansible-playbook site.yml ─── (loops)
 │      ├── play: localhost            → fetch PFX from KV, split to PEMs
 │      ├── play: nats_servers         → install, config, start nats-server
 │      ├── play: nats_clients         → install nats CLI
 │      └── play: nats_clients[0]      → pub/sub smoke test
 │
 └── ✅
```

Re-running `deploy.sh` is idempotent at both layers — Bicep is a declarative `az deployment`, and every Ansible task uses an idempotent module (`apt`, `template`, `copy`, `systemd`).

## 8. Trust & Security Boundaries

- **Key Vault** is the source of truth for the TLS material. Only `bphost`'s identity needs `Get`/`List` on the secret. The four NATS VMs never call Azure APIs at runtime.
- **SSH** is the only credential plane to the VMs. Public-key auth only (`disablePasswordAuthentication: true`).
- **TLS** terminates on each NATS server (the LB is L4 pass-through). Cluster traffic on 6222 is also TLS-wrapped using the same cert.
- **NSG** is intentionally permissive (lab). Production would scope SSH to a management CIDR and remove the 6222/8222 internet rule (cluster + monitoring should never be public).

## 9. Alternatives Considered

| Option                       | Why not (here)                                                            |
| ---------------------------- | ------------------------------------------------------------------------- |
| Stay on CSE                  | Brittle single-shell-string failures; no day-2 model.                      |
| `cloud-init` via `customData`| Better than CSE, but still bakes config into the deploy; no push-mode ops. |
| Packer-baked image           | Best for production; slower iteration than what a lab needs.               |
| Azure Automation DSC         | Windows-leaning, overkill for 6 VMs.                                       |

A future iteration can combine **Packer** (golden image with `nats-server` pre-installed) with **Ansible** (cert + config + cluster topology). The Ansible roles in this repo are already structured to be no-ops on a pre-baked binary.

## 10. Decisions & Trade-offs

- **Per-VM public IPs on NATS nodes** — adds 4 public IPs (cost) but removes the need for VNet peering between bphost and the lab VNet, and lets bphost address each node directly. The NSG already allowed SSH from the internet, so blast radius is unchanged.
- **Cert fetched once on bphost, distributed via Ansible** — single point of cert handling, no per-VM Azure CLI install, no KV access policy per MSI. Trade-off: the PEMs briefly exist on bphost in `/tmp/natslab-cert/`.
- **Cluster routes use private IPs from Bicep outputs** — rather than relying on Azure-provided short-name DNS. More resilient to DNS changes.
- **`client1` reached via `ProxyJump` through `client0`** — keeps `client1` private and provides a realistic two-tier client topology for tests.

## 11. Files in This Repo

```
NATSLab/
├── Spec.md                          # this file (architecture)
├── infra.parameters.example.json    # template — copy to infra.parameters.json
├── infra/
│   └── NATSDeploy.bicep             # infrastructure (no extensions)
├── docs/
│   ├── plan.md                      # implementation plan
│   └── runbook.md                   # operational walkthrough
├── scripts/
│   ├── bootstrap-bphost.sh          # one-time setup of bphost (ansible + az)
│   └── deploy.sh                    # run on bphost; orchestrates bicep + ansible
└── ansible/
    ├── ansible.cfg
    ├── group_vars/{all,nats_servers,nats_clients}.yml
    ├── playbooks/{site,servers,clients,smoketest}.yml
    └── roles/{common,nats-cert,nats-server,nats-client}/
```

See [docs/runbook.md](docs/runbook.md) for the step-by-step deploy walkthrough and day-2 operations.
