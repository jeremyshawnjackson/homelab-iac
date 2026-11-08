# Phase 4: Ansible, k3s and GitOps

Status: complete. Ansible configures the Proxmox host and every VM; a two-node k3s cluster runs on Terraform-provisioned VMs; Argo CD reconciles the cluster against this repository; `vzdump` writes nightly VM backups to the NAS.

After the one-time bootstrap, deploying a workload means committing a directory under `kubernetes/`. No playbook run and no `kubectl apply`.

## What it builds

| Target                      | Group               | Role(s)                     | Result                                                                                                     |
| --------------------------- | ------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Proxmox host `192.168.1.10` | `proxmox`           | `proxmox_host`              | Repositories, UTC clock, VFIO passthrough, GPU cluster mapping, cloud-init vendor-data, nightly backup job |
| `mgmt` 200                  | `vms`, `bastion`    | `base`, `kubectl`, `argocd` | Control node: `kubectl`, cluster kubeconfig, Argo CD bootstrap                                             |
| `k3s-server` 201            | `vms`, `k3s_server` | `base`, `k3s_server`        | k3s control plane, API on `:6443`                                                                          |
| `gpu-node` 202              | `vms`, `k3s_gpu`    | `base`, `k3s_agent`         | k3s agent, RTX 3080 attached, labelled and tainted                                                         |

Reserved static IPs: `.2` NAS, `.10` Proxmox, `.20` mgmt, `.21` k3s server, `.22` GPU node.

Pinned versions live in `group_vars`: k3s `v1.37.2+k3s1`, Argo CD `v3.6.1`. `kubectl` tracks the cluster's minor version, derived from `k3s_version` rather than pinned separately, because the supported skew is one minor version either side.

## Design decisions

| Decision                | Choice                                                       | Why                                                                                                               |
| ----------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| Config management       | Ansible, agentless over SSH                                  | No agent to install on a host that may be rebuilt; the Proxmox host is managed the same way as the guests         |
| Playbook split          | `host.yml`, `base.yml`, `k3s.yml`, `gitops.yml`              | Each is independently runnable; a cluster rebuild does not re-run host configuration                              |
| Kubernetes distribution | k3s                                                          | Single binary, SQLite datastore, bundled ingress and CNI; the full control plane fits in 8 GB alongside workloads |
| Datastore               | SQLite (default)                                             | One server node. etcd buys HA that a single hypervisor cannot provide                                             |
| Versions                | Pinned in `group_vars/all.yml`                               | A rebuild must produce the cluster this repository describes, not whatever released since                         |
| k3s configuration       | `/etc/rancher/k3s/config.yaml`                               | Declarative and re-readable, unlike installer flags baked into a systemd unit at install time                     |
| GitOps                  | Argo CD, app-of-apps                                         | Pull-based: the cluster reconciles itself against Git and corrects drift without CI holding cluster credentials   |
| Argo CD install         | `kubectl apply --server-side`                                | The ApplicationSet CRD exceeds the annotation limit client-side apply relies on                                   |
| Host-key policy         | `StrictHostKeyChecking=accept-new`, repo-local `known_hosts` | Trusts a host once; refuses a _changed_ key. A rebuilt VM on a reused IP fails loudly                             |
| Backups                 | `vzdump` on the host, CIFS to the NAS                        | Hypervisor-level, no agent in the guest; `fsfreeze` via the guest agent makes the snapshot application-consistent |

## 1. Inventory and layout

```
ansible/
  ansible.cfg          inventory path, roles path, SSH args, profile_tasks callback
  inventory.ini        groups: proxmox, vms, bastion, k3s_server, k3s_gpu
  group_vars/          all, vms, proxmox, bastion, k3s, k3s_gpu
  host.yml             Proxmox host configuration
  base.yml             every VM
  k3s.yml              control plane, control-node tooling, GPU agent
  gitops.yml           Argo CD bootstrap
  roles/               base, proxmox_host, k3s_server, k3s_agent, kubectl, argocd
kubernetes/
  bootstrap/root-app.yaml   the one imperatively applied object
  apps/                     Applications, discovered by the root
  workloads/                the manifests those Applications point at
```

The inventory is the single source of truth for addresses. `group_vars/k3s.yml` derives the server URL from it rather than repeating an IP:

```yaml
k3s_server_ip: "{{ hostvars['k3s-server'].ansible_host }}"
k3s_url: "https://{{ k3s_server_ip }}:6443"
```

## 2. The base role: created is not ready

Terraform reports a VM created the moment Proxmox starts it. Two tasks bridge the gap:

```yaml
- name: Wait for SSH to answer
  ansible.builtin.wait_for_connection:
    timeout: 300

- name: Wait for cloud-init to finish first boot
  ansible.builtin.command: cloud-init status --wait
  register: cloud_init
  changed_when: false
  # 2 = finished with recoverable errors; anything else is a real failure.
  failed_when: cloud_init.rc not in [0, 2]
```

The role then sets the timezone, installs base packages, enables the guest agent, turns on unattended security upgrades, and hardens `sshd` to key-only authentication. The `sshd` drop-in is written with `validate: /usr/sbin/sshd -t -f %s`, so a malformed config is rejected before the handler restarts the service. The failure mode that prevents is locking every key out of a remote host.

## 3. The Proxmox host role

### Clock

`vzdump` schedules are evaluated in the host's local timezone. The host shipped on `America/Los_Angeles` while every guest ran `Etc/UTC`, so a job written as `02:30` fired at `10:30` UTC. The whole fleet now agrees on UTC and only the display layer is local; a hypervisor on a different clock would force timezone arithmetic when correlating events.

### GPU as a cluster resource

Raw `hostpci` entries require `root@pam`. A _cluster PCI resource mapping_ can be delegated instead: `Mapping.Audit` and `Mapping.Use` scoped to `/mapping/pci/gpu-3080` let the non-root `terraform@pve` token attach the card by name.

Proxmox validates the mapping against live hardware on every VM start, and all five properties must be present:

| Property       | Value        | Source                                               |
| -------------- | ------------ | ---------------------------------------------------- |
| `node`         | `pve`        | Inventory hostname                                   |
| `path`         | `0000:01:00` | Both functions                                       |
| `id`           | `10de:2206`  | Vendor and device                                    |
| `iommugroup`   | `2`          | `readlink /sys/bus/pci/devices/<path>.0/iommu_group` |
| `subsystem-id` | `1043:87ac`  | `subsystem_vendor` + `subsystem_device`              |

The role reads the last two from sysfs rather than hard-coding them, because IOMMU group numbering changes when cards are added or moved. It compares the desired entry against the stored one as a _sorted set_ of properties: Proxmox does not promise to store them in the order they were given, so a string comparison would report drift on every run.

### cloud-init vendor-data

The role installs a snippet on shared storage, referenced by every VM through `vendor_data_file_id`:

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, start, qemu-guest-agent]
```

The `runcmd` line is not redundant. `qemu-guest-agent.service` is `static`: it has no `[Install]` section and cannot be enabled. It is activated instead by udev, through `SYSTEMD_WANTS` on the virtio serial port. That device event fires during boot, before cloud-init has installed the package or its udev rule, so nothing ever pulls the service in and it stays dead until the next reboot. Terraform waited out the full agent timeout and failed.

## 4. k3s

The server role writes configuration before installing, so the installer never runs with a different shape than the repository describes:

```yaml
node-ip: "{{ k3s_server_ip }}"
tls-san:
  - "{{ k3s_server_ip }}"
write-kubeconfig-mode: "0600"
secrets-encryption: true
```

`tls-san` is what makes the generated certificate valid for the LAN address, so `kubectl` works from mgmt rather than only from the node itself. `secrets-encryption` enables encryption at rest for Secrets. The default storage is plain base64, which any reader of etcd can decode.

Install is conditional on the running version, not on a file existing:

```yaml
- name: Read the installed k3s version
  ansible.builtin.command: k3s --version
  register: k3s_installed
  failed_when: false
  changed_when: false

- name: Install or upgrade k3s
  ...
  when: k3s_version not in k3s_installed.stdout
```

The agent role slurps the node token from the server, writes it under `no_log: true`, and joins. The label and taint are applied from the control node afterwards rather than through the installer's `node-label` and `node-taint` flags, which take effect only at first registration and are silently ignored on every later run:

```
nvidia.com/gpu.present=true
nvidia.com/gpu=present:NoSchedule
```

The label is vendor-prefixed because the NodeRestriction admission plugin forbids a kubelet from labelling itself into the `node-role.kubernetes.io/` namespace, since a compromised node could otherwise promote itself. The taint keeps general workloads off the card; anything that wants the GPU declares a toleration, which is also how it gets scheduled there.

DaemonSets are not exempt. Their automatic tolerations cover node _condition_ taints only (not-ready, unreachable, disk/memory/PID pressure, unschedulable), so `svclb-traefik` stays on the server node like everything else.

## 5. kubectl on the control node

The Kubernetes apt repository is per-minor-version, so the URI is derived rather than written twice:

```yaml
kubectl_minor: '{{ k3s_version | regex_search("^v[0-9]+\.[0-9]+") }}'
kubectl_repo_uri: "https://pkgs.k8s.io/core:/stable:/{{ kubectl_minor }}/deb/"
```

The repository is a _flat_ one, `suites: ["/"]` with no components, which `deb822_repository` expresses directly.

The server role then copies the cluster kubeconfig to mgmt, rewriting the loopback address k3s generates:

```yaml
content: >-
  {{ k3s_kubeconfig.content | b64decode
     | replace('127.0.0.1', k3s_server_ip) }}
```

## 6. GitOps

```
gitops.yml -> argocd role
  create namespace
  kubectl apply --server-side --force-conflicts -f <pinned manifest URL>
  wait for the CRDs to be established
  wait for 6 Deployments + 1 StatefulSet to roll out
  kubectl apply -f kubernetes/bootstrap/root-app.yaml
```

That last object is the only imperative one in the cluster's lifetime. It points Argo CD at `kubernetes/apps/` with `recurse: true`, `prune: true` and `selfHeal: true`. Argo reads that directory from GitHub, finds `demo.yaml`, creates the `demo` Application, which creates its namespace and workload. The entire chain after the root apply happens without a human.

`prune` means deleting a manifest deletes the object; `selfHeal` means a manual `kubectl edit` is reverted within minutes. Together they make Git the only way to change the cluster.

### Server-side apply is required, not preferred

Client-side apply stores a full copy of each manifest in the `kubectl.kubernetes.io/last-applied-configuration` annotation so it can compute three-way diffs later. The `applicationsets.argoproj.io` CRD embeds a complete OpenAPI schema and exceeds the 256 KiB annotation ceiling:

```
metadata.annotations: Too long: may not be more than 262144 bytes
```

Server-side apply has no such limit: ownership is tracked per field in `metadata.managedFields` and no copy of the manifest is stored. `--force-conflicts` takes ownership from the partial client-side apply that preceded it.

The cost is honest and recorded in the role: server-side apply prints `serverside-applied` for every object whether or not anything changed, so Ansible cannot report drift on that task. `changed_when: false` is the truthful answer rather than a guess.

### Waiting for the CRDs

The upstream manifest creates the CRDs and the controllers that watch them in a single apply, with no ordering between them. A controller that starts first asks the API server to watch a kind that does not exist yet, retries for the length of controller-runtime's cache-sync deadline, and exits non-zero:

```
no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"
...
failed to wait for applicationset caches to sync: timed out waiting for cache to be synced
```

Exactly 120 seconds, then `Exit Code: 1`, then a kubelet restart, repeating. The role now blocks on `kubectl wait --for condition=established` for each CRD before anything depends on them.

The rollout checks added alongside are weaker than they look, and the role says so: `rollout status` returns when replicas report _available_, and the crash-looping controller's readiness probe passed the whole time, because the health port binds long before cache sync finishes. Those checks catch a component that never starts. One that starts and then dies gets past them, and detecting that is alerting's job (Phase 6).

## 7. Nightly backups to the NAS

A dedicated Synology service account holds read/write on one share. CIFS has no key-based authentication, so a password is unavoidable; it is generated with `RandomNumberGenerator.GetInt32` (not `Get-Random`, which is not cryptographic), stored in the workstation's SecretManagement vault, and passed to `pvesm` through a shell variable so that history records `--password "$PW"` rather than the secret:

```bash
read -rs PW        # echo is off; paste and press Enter
pvesm add cifs nas-backup --server ... --password "$PW" ...
unset PW
```

The role does not create the storage. It asserts that it exists and fails with the exact command to run, because the alternative is a password in a playbook.

```yaml
storage: nas-backup
schedule: 02:30
prune: keep-daily=7,keep-weekly=4
exclude: 9000 # the template is reproducible from the upstream image
mode: snapshot # QEMU dirty-block tracking, not storage snapshots
```

`keep-daily=7` keeps the most recent backup from each of the last seven days. The retention unit is the day, so a day with two runs still leaves one file behind. The Synology recycle bin is disabled on this share: it intercepts deletes, so Proxmox's prune would appear to succeed while nothing was actually freed.

Verified run: `fsfreeze` and `fs-thaw` issued through the guest agent, 93 % of the 32 GB disk detected sparse, 600 MB archive, prune removed the expired backup.

## 8. Exercises and results

| Exercise                         | Result                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------- |
| `host.yml` re-run                | `changed=0`, 6 skipped                                                          |
| `k3s.yml` first run              | `changed=9`; re-run `changed=0`                                                 |
| `kubectl` from mgmt              | Works, proving the `tls-san` entry                                              |
| GPU attached through the mapping | `10de:2206` and `10de:1aef` visible in the guest, attached by a non-root token  |
| Taint honoured                   | Every pod on `k3s-server`, including DaemonSets                                 |
| Root Application applied         | `demo` Application, namespace and workload created with no further human action |
| Ingress                          | `curl -H 'Host: demo.lab.local' http://192.168.1.21` served nginx               |
| Nightly backup                   | Application-consistent, 600 MB, prune correct                                   |

### GPU node rebuild drill

`terraform apply -replace='proxmox_virtual_environment_vm.k3s["gpu-node"]'`, then `base.yml` and `k3s.yml`.

| Step                                         | Time                      |
| -------------------------------------------- | ------------------------- |
| VM destroy and recreate                      | 2 m 20 s                  |
| `base.yml` + `k3s.yml`                       | ~40 s                     |
| Node `Ready`, labelled, tainted, GPU present | ~52 s after agent install |

`demo` ran uninterrupted throughout and both Applications stayed `Synced/Healthy`: a node leaving and rejoining did not perturb Argo CD. Two cleanups were needed between destroy and rejoin: pruning the stale host key, and deleting the `Node` object.

## 9. Lessons

- **A rebuilt node comes back on the template's kernel.** The new GPU node booted `6.1.0-53` while its neighbour, alive long enough for unattended-upgrades to have run, was on `6.1.0-54`. Fleet uniformity silently depends on uptime.
- **The host-key refusal is the feature.** `accept-new` trusts a host once and refuses a changed key, so every legitimate rebuild on a reused IP needs a human to vouch for it. Correct behaviour, and it does not scale.
- **Idempotence has to be designed for CLI tools.** Tasks wrapping `pvesh` and `pvesm` read current state, compare, and act only on a difference. Without that, `changed` is meaningless and real drift is invisible.
- **`jq` is not installed on a stock Proxmox host.** `pvesh --output-format yaml` avoids adding a package just to parse output. A broken-pipe error alongside `command not found` is one cause, not two.

## 10. Known gaps

Recorded rather than silently carried.

| Gap                                                        | Consequence                                                               | Addressed in |
| ---------------------------------------------------------- | ------------------------------------------------------------------------- | ------------ |
| Backup notifications go to `mail-to-root` with no MTA      | A failed backup is silent                                                 | Phase 6      |
| The k3s join token is permanent and unrotated              | Anyone holding it can join a node; `k3s token create --ttl` is the answer | Phase 7      |
| The k3s installer's checksum is not verified               | TLS authenticates the host, not the binary                                | Phase 7      |
| Backups cover VMs, not in-cluster state                    | A restored VM is not a restored application                               | Phase 8      |
| The hypervisor can delete its own backups                  | Ransomware reaches both; immutability or a pull-based copy is the fix     | Phase 8      |
| Host keys change on every rebuild                          | Manual intervention per rebuild; SSH certificates are the fleet answer    | Backlog      |
| The GPU node's 200 GB data disk is part of the VM resource | `terraform -replace` destroys it, and it will hold the model library      | Phase 5      |
| Argo CD UI has no DNS or trusted certificate               | Reachable only through `kubectl port-forward`                             | Backlog      |
