# NATSLab

A four-node NATS.io cluster plus two clients in Azure, used to test NATS features. Software install and config are decoupled from the Azure resource deploy — Bicep owns infrastructure, Ansible (driven from the `bphost` control VM) owns everything that runs on the VMs.

## Quick start

On `bphost`:

```bash
git clone <this-repo-url> ~/NATSLab
cd ~/NATSLab
sudo ./scripts/bootstrap-bphost.sh        # one-time
cp infra.parameters.example.json infra.parameters.json
$EDITOR infra.parameters.json             # set adminUsername + adminSshPublicKey
az login --identity                       # or: az login
./scripts/deploy.sh
```

## Docs

- [Spec.md](Spec.md) — architecture and design rationale
- [docs/runbook.md](docs/runbook.md) — operational walkthrough and day-2 procedures
- [docs/plan.md](docs/plan.md) — the implementation plan this repo was built from

## Layout

```
infra/NATSDeploy.bicep   Azure infrastructure (no script extensions)
ansible/                 Roles, playbooks, group_vars, generated inventory
scripts/deploy.sh        Orchestrates: bicep -> render inventory -> ansible
```
