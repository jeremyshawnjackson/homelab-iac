# Hardware

Current state of the lab hardware. Phase docs record when and why things changed; this page always describes what is installed now.

Last updated: 2026-11-13 (during Phase 5).

## Proxmox host (`pve`, 192.168.1.10)

| Component   | Detail                                                                | Notes                                                                                                        |
| ----------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Motherboard | ASUS Z170M-PLUS, BIOS 3805 (2018-05-16)                               | Micro-ATX, Z170 chipset                                                                                      |
| CPU         | Intel Core i5-6600, 4 cores / 4 threads                               | VT-x and VT-d                                                                                                |
| RAM         | 16 GB: Corsair Vengeance LPX 1×16 GB DDR4 in DIMM_A2                  | Single channel at DDR4-2133. Verified under concurrent load with `stress-ng --vm 4 --vm-method all --verify` |
| Disk 1      | Samsung 850 EVO 250 GB SSD                                            | Proxmox OS, `local`, `local-lvm` (VM disks)                                                                  |
| Disk 2      | Seagate FireCuda 2 TB SSHD                                            | `bulk`: ISOs, backups, snippets                                                                              |
| Disk 3      | Seagate FireCuda 2 TB SSHD, NTFS                                      | Not mounted and unused by Proxmox. 40 uncorrectable sectors                                                  |
| NIC         | Intel X550 dual-port 10GBASE-T (third-party board), `ixgbe`           | Ports pinned by MAC as `nic0` (uplink, `vmbr0`) and `nic1` (reserved). Links at 1 Gb/s to the router         |
| Onboard NIC | Intel I219-V                                                          | Dead: `e1000e` fails to initialize it. Unused                                                                |
| iGPU        | Intel HD Graphics 530                                                 | Host console; primary display                                                                                |
| GPU         | ASUS ROG Strix RTX 3080 (10 GB), `10de:2206` / audio `10de:1aef`      | CPU x16 slot. Bound to `vfio-pci` on the host for passthrough. Link trains at **x8** (see Known issues)      |
| PSU         | Corsair RM750 (2019), model RPS0119, part CP-9020195, 750 W, 80+ Gold | Fully modular, Corsair Type 4 cables only. GPU on three separate PCIe cables                                 |

Location: network closet next to the router. In-wall cabling elsewhere in the house only supports 100 Mb/s.

## BIOS settings

| Setting                         | Location                                         | Value            | Why                                                            |
| ------------------------------- | ------------------------------------------------ | ---------------- | -------------------------------------------------------------- |
| Intel Virtualization Technology | Advanced → CPU Configuration                     | Enabled          | KVM                                                            |
| VT-d                            | Advanced → System Agent (SA) Configuration       | Enabled          | IOMMU for PCI passthrough                                      |
| Above 4G Decoding               | Advanced → System Agent (SA) Configuration       | Enabled          | Room to map the GPU's large BARs                               |
| Primary Display                 | Advanced → System Agent → Graphics Configuration | CPU Graphics     | Host console stays on the iGPU; the host never claims the 3080 |
| iGPU Multi-Monitor              | Advanced → System Agent → Graphics Configuration | Enabled          | Keeps the iGPU active with a discrete GPU installed            |
| Wait for F1 if error            | —                                                | Disabled         | Boots without a keyboard                                       |
| Restore on AC power loss        | —                                                | Power On         | Recovers from outages unattended                               |
| Memory frequency                | Ai Tweaker                                       | Auto (DDR4-2133) | The rated speed for this memory controller. XMP off            |

## Power control

The host has no IPMI, so a Shelly Plug US Gen4 between the wall and the PSU is the lab's only out-of-band power control. It will allow a powered-off or wedged host recoverable remotely, and it meters the whole machine at the wall, which `nvidia-smi` cannot.

| Item     | Value                               | Notes                                                                                                        |
| -------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Device   | Shelly Plug US Gen4, `S4PL-00116US` | Device id `shellyplugusg4-98c377023394`, mDNS `ShellyPlugUSG4-98C377023394.local`                            |
| Address  | 192.168.1.111                       | Reserved lease. Ansible addresses it by IP: the Debian cloud image has no mDNS resolver                      |
| Firmware | 2.2.0                               | Shipped on 1.7.99; 2.0.3 was a required intermediate hop                                                     |
| Rating   | 15 A / 1800 W                       | Host plus the 3080 peaks near 450 W, so the limit is not a realistic trip                                    |
| Cloud    | Disabled                            | Control is the device's local RPC API only; no vendor service between Ansible and the relay                  |
| Auth     | HTTP digest, user `admin`           | Password in `ansible/group_vars/bastion.sops.yml`, encrypted to the same age identity as the cluster secrets |

Operated by [`ansible/power.yml`](../ansible/power.yml), which runs on `mgmt` with no facts gathered and nothing reached over SSH, so it still works when the Proxmox host is exactly what is unreachable. A plain run reports relay state and metering; `-e shelly_relay_state=on` applies mains and waits for the host's SSH port, which is also the standing check that **Restore on AC power loss: Power On** is still set.

Two safety properties are worth stating, because the plug is a power cut and not a shutdown:

- `initial_state: restore_last` and `autorecover_voltage_errors: true` are converged on every run. A plug that reboots for its own reasons, or trips its voltage protection, must not leave the host unpowered with nobody watching.
- Opening the relay is refused while the plug reads more than `shelly_standby_watts`. The power meter is the evidence that a shutdown actually finished, which is a better gate than a fixed sleep. `-e shelly_force_cut=true` overrides it, for a host too wedged to shut itself down and accepting an unclean loss.

The role computes the digest itself rather than letting `ansible.builtin.uri` do it. `uri` is built on Python's `urllib`, which implements only MD5 and SHA-1, while this firmware challenges with SHA-256. Two things cost a round trip each on the way to a working call: the nonce is base64, so it carries `/`, `+` and `=` and a character-class regex mangles it; and `ha2` is transport-dependent, hashing the fixed `dummy_method:dummy_uri` over WebSocket but the real `POST:/rpc` over HTTP, which is what most example code in the wild gets wrong for this transport.

Only the host is on the plug. The switch, router and NAS are deliberately not: the plug is controlled over the network it would be cutting, and the NAS is the nightly `vzdump` target.

## IOMMU

- Firmware DMAR table present; two remapping units: `dmar0` (iGPU) and `dmar1` (all other PCI devices, `INCLUDE_PCI_ALL`).
- Interrupt remapping enabled (x2apic mode).
- The Proxmox kernel enables the Intel IOMMU by default; no `intel_iommu=on` kernel parameter needed.

Check:

```bash
dmesg | grep -e DMAR -e IOMMU
dmesg | grep -i remapping
ls /sys/class/iommu/          # dmar0 dmar1
```

## PCIe layout

| Root port           | Bus | Device                                      | Slot                             |
| ------------------- | --- | ------------------------------------------- | -------------------------------- |
| `00:01.0` (CPU)     | 01  | RTX 3080 (`01:00.0` video, `01:00.1` audio) | CPU x16 slot                     |
| `00:1b.0` (chipset) | —   | Empty                                       | Not yet mapped                   |
| `00:1c.0` (chipset) | —   | Empty                                       | Not yet mapped                   |
| `00:1c.4` (chipset) | 04  | Intel X550 (`04:00.0`, `04:00.1`)           | Chipset x16 slot (x4 electrical) |
| `00:1d.0` (chipset) | —   | Empty                                       | Not yet mapped                   |

Bus numbers for chipset devices can change when cards are added (the X550 moved from bus 03 to 04 when the GPU went in); interface names are pinned by MAC, so this doesn't affect networking.

IOMMU group 2 holds only the RTX 3080's two functions and its CPU root port; every chipset device is in its own group. Full listing in [03-gpu-passthrough.md](03-gpu-passthrough.md).

## GPU passthrough configuration

| Item                  | Value                                                                                                                                                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Host binding          | `/etc/modprobe.d/vfio.conf`: `options vfio-pci ids=10de:2206,10de:1aef`, `softdep nouveau pre: vfio-pci`                                                                                                                                                                                                                       |
| Host blacklist        | `/etc/modprobe.d/blacklist-nvidia.conf`: `nouveau`, `nvidiafb`, `nvidia`                                                                                                                                                                                                                                                       |
| Modules at boot       | `vfio`, `vfio_iommu_type1`, `vfio_pci` in `/etc/modules`                                                                                                                                                                                                                                                                       |
| Subsystem ID          | `1043:87ac`. Identifies this specific board rather than the chip. Proxmox validates it against live hardware on every VM start as part of the cluster PCI mapping                                                                                                                                                              |
| Guest VM requirements | `q35`, OVMF with Secure Boot off, `hostpci0` via the `gpu-3080` cluster mapping with `pcie=1`, ballooning off, cloud-init drive on SCSI                                                                                                                                                                                        |
| Guest driver          | NVIDIA repository, 620.70.06 (open kernel module), installed and held by `ansible/roles/gpu_runtime`. `nvidia-kernel-open-dkms` and `nvidia-driver-cuda` only: the `cuda-drivers` and `nvidia-open` metapackages depend on `nvidia-settings` and `nvidia-xconfig`, which pull GTK and X fonts onto a node with no display path |
| Power tuning          | `nvidia-smi -lgc 210,1650` in the guest: ~270 W and 65 °C sustained vs ~368 W at stock, for −2.8% inference speed. Runtime setting, applied at boot from Phase 5                                                                                                                                                               |

## Known issues

| Issue                    | Detail                                                                                                                                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GPU PCIe link at x8      | `LnkCap` x16, but the link runs at x8 even under load, after one reseat. Suspect slot, board or card contacts. Low impact on inference                                                                                                |
| Onboard I219-V NIC       | Dead; unused                                                                                                                                                                                                                          |
| G.Skill DIMM pair faulty | Both 16 GB Trident Z Neo sticks fail memory verification in either slot at stock DDR4-2133. Returned under warranty. The host runs on a single 16 GB Corsair stick until they are replaced, which is not enough to start the GPU node |

## Spare hardware

Candidates for a second GPU. Not decided: a second node, a second GPU on this host via an x1 riser, or none.

| Component   | Detail                                                                                        |
| ----------- | --------------------------------------------------------------------------------------------- |
| Motherboard | ASUS ROG Strix X570-I (mini-ITX, one x16 slot)                                                |
| CPU         | None yet (AM4)                                                                                |
| GPU         | EVGA RTX 3070 FTW3 (8 GB)                                                                     |
| Case        | FormD T1 (Mini-ITX, SFX/SFX-L PSU only, GPU up to 325 mm and 3.25 slots, riser-mounted)       |
| PSU         | Corsair CX750M (750 W, Bronze, semi-modular, ATX), removed from this host. Doesn't fit the T1 |

AMD-Vi/IOMMU groups to be verified once a CPU is installed.
