# homelab-iac

A self-hosted home services platform built as code: Proxmox on bare metal, Terraform-provisioned VMs, k3s with GitOps deployment, a GPU-accelerated local LLM, and Prometheus/Grafana observability.

Status: in progress. Phases 1–4 complete: a two-node k3s cluster runs on Terraform-provisioned VMs with the RTX 3080 passed through to the GPU node, Argo CD reconciles the cluster against this repository, and `vzdump` writes nightly VM backups to the NAS.

## Architecture

The two k3s VMs *are* the cluster's nodes, so the cluster is drawn as a layer over them rather than as a box beside them. The k3s server runs the control plane and, untainted by default, workloads as well. `mgmt` is deliberately not a cluster member: it holds `kubectl` and ran the one-time Argo CD bootstrap, so losing it costs a convenience rather than capacity. Workloads marked *planned* arrive in phases 5 and 6.

Two reconciliation loops with different scopes. Ansible is pushed by a human and owns the host and the VMs down to the OS. Argo CD is pulled by the cluster, continuously, and owns everything inside it, including workloads scheduled onto the GPU node. Neither reaches into the other's territory.

```mermaid
flowchart TB
  tf["Terraform<br/>bpg/proxmox, scoped API token"]
  ans["Ansible"]

  subgraph host["Proxmox VE host · i5-6600 · 32 GB · RTX 3080"]
    direction TB
    tpl["Template 9000<br/>Debian 12 cloud-init"]
    mgmt["mgmt VM — control node<br/>kubectl, Argo CD bootstrap"]

    subgraph k3s["k3s cluster"]
      direction LR
      srv["k3s server VM<br/>control plane, schedulable<br/>Argo CD · observability (planned)"]
      gpu["GPU node VM<br/>RTX 3080 via VFIO, tainted<br/>Ollama / vLLM, DCGM (planned)"]
    end
  end

  repo[("This repository")]
  nas[("NAS")]

  tf -->|clones| tpl
  ans -->|configures host and VMs| host
  tpl --> mgmt
  tpl --> k3s
  repo -->|Argo CD reconciles| k3s
  host -->|nightly vzdump| nas
```

## Phases

| # | Phase | Status | Doc |
| --- | --- | --- | --- |
| 1 | Proxmox on bare metal: storage, networking, cloud-init template | Done | [01-proxmox.md](docs/01-proxmox.md) |
| 2 | Terraform provisioning with a least-privilege API token | Done | [02-terraform.md](docs/02-terraform.md) |
| 3 | GPU hardware validation and passthrough (gate) | Done | [03-gpu-passthrough.md](docs/03-gpu-passthrough.md) |
| 4 | Ansible + k3s, GitOps bootstrap, nightly VM backups to NAS | Done | [04-ansible-k3s.md](docs/04-ansible-k3s.md) |
| 5 | GPU workloads on k3s: NVIDIA stack, local LLM (Ollama, then vLLM; models benchmarked across both) | Planned | |
| 6 | Observability: metrics, logs, GPU metrics, alerts, one SLO | Planned | |
| 7 | CI with progressive delivery and automated rollback | Planned | |
| 8 | Backups, restore drills, failure drills, postmortems | Planned | |
| 9 | Python triage tool using Prometheus, Loki and the local LLM | Planned | |

Hardware: [docs/hardware.md](docs/hardware.md). Future work: [docs/backlog.md](docs/backlog.md).

## Repository layout

```
terraform/   VM provisioning (bpg/proxmox)
ansible/     Proxmox host and VM configuration, k3s install, Argo CD bootstrap
kubernetes/  manifests Argo CD reconciles: bootstrap, apps, workloads
docs/        phase write-ups, hardware reference, backlog
```

Secrets, Terraform state and variable files are gitignored; `terraform/example.tfvars` shows the expected variables.
