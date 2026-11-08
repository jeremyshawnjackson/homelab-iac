# Phase 5: GPU workloads on k3s

Status: in progress. The GPU node is sized for hybrid CPU/GPU inference and its
data disk is mounted and exported to the cluster as local PersistentVolumes.

## Design decisions

| Decision                | Choice                                      | Why                                                                                                     |
| ----------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| GPU node memory         | 20 GB, ballooning off                       | A 30B MoE at Q4 holds ~18.6 GB of weights against 10 GB of VRAM, so the expert blocks live in system RAM |
| Model library location  | Local volumes on the GPU node's data disk   | Weights are a reproducible cache; a network dependency on the pod start path costs more than it returns |
| Disk identity           | GPT partition name                          | `/dev/sdb` is whatever the kernel enumerated this boot; `by-partlabel` survives reordering and rebuilds |
| Volume binding          | `WaitForFirstConsumer`                      | A local volume is reachable from one machine, so the bind must follow the scheduler rather than lead it |
| Reclaim policy          | `Retain`                                    | Deleting a PVC must not delete the library                                                              |

## 1. Node memory

The host has 32 GB, reported by the kernel as 31 GiB. The GPU node's share is
not negotiable: VFIO pins the whole guest address space, so its memory is
resident from boot and cannot be swapped or reclaimed under pressure. The other
two VMs are sized around that reservation.

| VM           | Memory | Notes                                            |
| ------------ | ------ | ------------------------------------------------ |
| `gpu-node`   | 20 GB  | Pinned by VFIO. Sized for MoE expert blocks      |
| `k3s-server` | 6 GB   | Control plane, Argo CD, observability stack      |
| `mgmt`       | 2 GB   | Ansible and `kubectl`, no workload               |

Ballooning is off everywhere, which has a consequence worth stating: QEMU's
resident size is a high-water mark. Without a balloon driver a guest that frees
memory keeps those pages as page cache, so they stay faulted in and the
hypervisor never gets them back. Steady-state host usage is therefore the sum
of the allocations plus roughly 1.7 GB of QEMU and Proxmox overhead, near 29.7
of the 31 GiB available.

The pressure point is starting the GPU node, where VFIO demands all 20 GB at
once and the start fails if the host cannot produce it. After a full shutdown
the nodes are started GPU first, while the host is empty. The k3s agent retries
its connection, so it does not matter that the server is not up yet.

```bash
qm start 202 && sleep 30 && qm start 201 && sleep 20 && qm start 200
```

## 2. Where the model library lives

The GPU node carries a 200 GB disk on the host's SSHD, separate from the 32 GB
OS disk on the SSD. The question this phase settles is whether the model
library belongs there or on the NAS over NFS.

| | Local disk | NFS from the NAS |
| --- | --- | --- |
| Sequential read | ~190 MB/s | ~110 MB/s, capped by the 1 Gb/s link |
| Cold load, 18.6 GB model | ~100 s | ~170 s |
| Survives node loss | No | Yes |
| Pod start depends on | The node itself | The node and the NAS |

The argument that usually decides this is survivability, and here it carries
less weight than it appears to. Model weights are a reproducible cache: losing
them costs the time to pull them again from an upstream registry, not
information. Against that, NFS puts the NAS on the pod start path, so a NAS
reboot turns every inference pod into `ContainerCreating`. A GPU-bound workload
acquiring a network dependency for its hot path is the wrong trade, so the
library stays local.

### Claiming the disk

Terraform attaches the disk as a bare block device. `roles/model_storage`
partitions, formats and mounts it, and identifies it by what it is rather than
by a name the kernel assigns at enumeration time. The role asserts that exactly
one unpartitioned disk of the expected size is present and refuses to act
otherwise, because the failure mode of guessing is partitioning the OS disk.

A GPT partition name gives the disk a stable handle afterwards, so
`/dev/disk/by-partlabel/modellib` is what `/etc/fstab` refers to. Two details
in the role carry reasoning worth keeping:

- `mkfs.ext4 -m 1` drops the root-reserved block count from 5% to 1%. That
  reserve lets root still write on a full root filesystem, which a data-only
  volume does not need, and 5% of 200 GB is ~8 GB.
- The mount has no `nofail`. If the disk is absent, the node must not boot into
  a state where the local volume paths resolve to empty directories on the
  32 GB OS disk and Kubernetes begins filling it. A VM that stops at the
  console is the louder and more recoverable of the two failures.

ext4 rather than XFS: XFS's advantage on large files comes from parallel
allocation across allocation groups, which pays off on fast multi-queue
storage. One spinning disk does not provide the parallelism for that to matter.

### Exporting it to the cluster

Two directories on the one filesystem, each a `PersistentVolume` in the
`model-library` StorageClass.

| Volume | Path | Consumers |
| --- | --- | --- |
| `model-library-ollama` | `/var/lib/models/ollama` | Ollama's own blob store |
| `model-library-huggingface` | `/var/lib/models/huggingface` | vLLM and llama.cpp |

The split follows the distribution model rather than the runtime. Ollama serves
models from its own registry and keeps its own layout; vLLM and llama.cpp both
read the Hugging Face cache, so they share one volume.

`volumeBindingMode: WaitForFirstConsumer` is what makes a local volume safe.
Binding immediately would claim a PV before the scheduler has chosen a node,
and a local volume is reachable from exactly one machine. Deferring the bind
until a pod is scheduled lets the volume's node affinity constrain placement
instead of contradicting it. That affinity is written against
`kubernetes.io/hostname` rather than the GPU label, because the disk is in one
specific machine and a second GPU node would match the label without holding
the data.

Capacity on a local volume is advisory. Both volumes are directories on one
filesystem, so neither figure is enforced and either can fill the disk. Real
isolation would mean a logical volume per PV, which buys enforcement at the
cost of fixing the split at format time.

## 3. Known gaps

| Gap | Consequence | Addressed in |
| --- | --- | --- |
| The data disk is declared inside the VM resource | `terraform -replace` on the GPU node destroys the library. Recovery is a re-download, which is the reason the library is treated as a cache | Phase 8 |
| Local volume capacity is not enforced | One workload can fill the disk and starve the others | Backlog |
