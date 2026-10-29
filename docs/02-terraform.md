# Phase 2: Terraform provisioning

Status: complete. Terraform provisions VMs from template 9000 through a least-privilege API token. A full `terraform apply` takes about 15 seconds and `terraform destroy` about 3 seconds.

## What it builds

| VM | ID | Source | Network | Resources | State after apply |
| --- | --- | --- | --- | --- | --- |
| `mgmt` | 200 | Full clone of template 9000 | `vmbr0` static `192.168.1.20/24` | 2 vCPU, 4 GB, 32 GB disk | Running |

Phase 4 extends this configuration with the k3s server and GPU node VMs.

Reserved static IPs on the home LAN: `.2` NAS, `.10` Proxmox, `.20` mgmt VM.

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Provider | `bpg/proxmox` (lock file pins 0.118.0) | Actively maintained, broader coverage than the older Telmate provider |
| Auth | Dedicated `terraform@pve` user + API token, custom role | Least privilege; token revocable on its own; never root's password |
| Secrets | Environment variables (later: CI credentials) | Nothing secret in `.tf` or `.tfvars`, so nothing to leak via Git |
| Mgmt IP | Static | Terraform doesn't need the guest agent to discover it |
| Mgmt clone | Full | Independent of the template, so the template can be rebuilt |
| Guest agent | Disabled for now | Installed by Ansible in Phase 4; otherwise Terraform waits for an agent that isn't there |

## 1. Proxmox user, role and token

```bash
pveum user add terraform@pve --comment "Terraform provisioning"

pveum role add TerraformProv -privs "Datastore.AllocateSpace Datastore.Audit Sys.Audit SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt VM.GuestAgent.Audit"

pveum aclmod / -user terraform@pve -role TerraformProv

pveum user token add terraform@pve tf --privsep 0   # secret is shown once
```

- `@pve` realm: Proxmox-only user, no host shell login.
- `--privsep 0`: token inherits the user's permissions (otherwise the token needs its own ACLs).

Rotation:

```bash
pveum user token remove terraform@pve tf
pveum user token add terraform@pve tf --privsep 0
```

## 2. Workstation setup (Windows)

```powershell
winget install HashiCorp.Terraform

$env:PROXMOX_VE_ENDPOINT  = "https://192.168.1.10:8006/"
$env:PROXMOX_VE_API_TOKEN = "terraform@pve!tf=<secret>"
```

Environment variables last for one terminal session. To avoid re-entering (and losing) the secret, store it encrypted with PowerShell SecretManagement:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name lab -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name pve-tf-token -Secret "terraform@pve!tf=<secret>"
$env:PROXMOX_VE_API_TOKEN = Get-Secret pve-tf-token -AsPlainText   # each session
```

## 3. Configuration layout

| File | Contents |
| --- | --- |
| `versions.tf` | Terraform and provider version constraints; provider block (`insecure = true` for the self-signed host cert) |
| `variables.tf` | `node`, `template_id`, `ssh_public_key`, mgmt IP and gateway |
| `mgmt.tf` | Mgmt VM: full clone, disk, NIC, cloud-init (static IP, DNS, `admin` user + SSH key) |
| `outputs.tf` | Mgmt IP |
| `example.tfvars` | Placeholder values (committed) |
| `terraform.tfvars` | Real values (gitignored) |
| `.terraform.lock.hcl` | Exact provider version and checksums (committed) |

Gitignored: `.terraform/`, `*.tfstate*`, `*.tfvars` (except the example), saved plans (`tfplan`).

## 4. Workflow

```powershell
terraform init                 # download provider, write lock file
terraform fmt                  # canonical formatting (only runs on files that parse)
terraform validate             # syntax and types, no API calls
terraform plan -out tfplan     # review exactly what will change
terraform apply tfplan         # apply exactly the reviewed plan, no re-plan
terraform output
```

A saved plan guarantees the apply matches what was reviewed. This is the shape of the CI pipeline in Phase 7: plan stage, approval gate, apply the saved plan.

## 5. Provider defaults changed after reading the plan

The plan shows the full resulting configuration, including defaults not written in code. Changes made after reviewing it:

| Default | Change | Reason |
| --- | --- | --- |
| Mgmt `scsi_hardware = "virtio-scsi-pci"` | `virtio-scsi-single` | Provider default overrode the template's controller |
| `discard = "ignore"` | `"on"` | LVM-thin: freed guest blocks return to the pool |
| `ssd = false` | `true` | Disks are on the 850 EVO; guest uses SSD behavior and TRIM |
| `iothread = false` | `true` | Each disk gets its own I/O thread with `virtio-scsi-single` |

Reference: the provider's `proxmox_virtual_environment_vm` page on the Terraform Registry, `man qm` on the host, or `terraform providers schema -json`.

## 6. Exercises and results

| Exercise | Result |
| --- | --- |
| Plan after apply | "No changes" |
| Drift: a VM's memory changed in the GUI | Plan showed `~ update in-place` reverting it; apply took 0 s; same VM (MAC unchanged) |
| `terraform destroy` | 2.7 s |
| `terraform apply` from empty | 14.5 s (dominated by the full clone of the mgmt disk) |

Plan symbols: `+` create, `~` update in place, `-/+` destroy and recreate (the triggering attribute is marked `# forces replacement`), `-` destroy.

## 7. Lessons

- **Created is not ready.** Terraform reports the VM created once Proxmox starts it. SSH stalled until cloud-init finished first boot (~40 s). Phase 4's first Ansible tasks: `wait_for_connection`, then `cloud-init status --wait`.
- **Host keys change on every rebuild.** Same IP, new VM, new keys: `ssh-keygen -R 192.168.1.20`. Ansible will need a host-key strategy for rebuilt VMs.
- **401 vs 403.** 401 = the credential wasn't recognized (wrong or rotated secret, empty variable); 403 = recognized but lacking a privilege. Diagnosed by testing the API directly, without Terraform:

  ```powershell
  curl.exe -k -i -H "Authorization: PVEAPIToken=$env:PROXMOX_VE_API_TOKEN" https://192.168.1.10:8006/api2/json/version
  $env:PROXMOX_VE_API_TOKEN.Split('=')[0]   # must be terraform@pve!tf
  $env:PROXMOX_VE_API_TOKEN.Length          # 53
  ```

- **`Measure-Command` hides output.** Pipe to `Out-Default` to see whether the timed command succeeded.
- **`~> 0.117` allows newer 0.x versions** (0.118.0 was installed); the committed lock file pins the exact version for everyone, including CI.

## Open question: where state lives

State currently lives on the workstation. Once CI runs Terraform (Phase 7), state cannot live on a VM that Terraform itself creates and destroys. Options to decide: a remote backend with locking on the NAS (S3-compatible or Postgres), or splitting the configuration so long-lived infrastructure is managed separately from disposable VMs.
