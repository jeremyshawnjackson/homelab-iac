# Hardware

Current state of the lab hardware. Phase docs record when and why things changed; this page always describes what is installed now.

Last updated: 2026-10-29 (Phase 3, before GPU install).

## Proxmox host (`pve`, 192.168.1.10)

| Component | Detail | Notes |
| --- | --- | --- |
| Motherboard | ASUS Z170M-PLUS, BIOS 3805 (2018-05-16) | Micro-ATX, Z170 chipset |
| CPU | Intel Core i5-6600, 4 cores / 4 threads | VT-x and VT-d |
| RAM | 32 GB: G.Skill Trident Z Neo 2×16 GB DDR4 in DIMM_A2 + DIMM_B2 | Dual channel. Rated DDR4-3600; runs at DDR4-2944, CL16-19-19-39. Memtest86+ 7.20: 19 passes, 0 errors |
| Disk 1 | Samsung 850 EVO 250 GB SSD | Proxmox OS, `local`, `local-lvm` (VM disks) |
| Disk 2 | Seagate FireCuda 2 TB SSHD | `bulk`: ISOs, backups, snippets |
| NIC | Intel X550 dual-port 10GBASE-T (third-party board), `ixgbe` | Ports pinned by MAC as `nic0` (uplink, `vmbr0`) and `nic1` (reserved). Links at 1 Gb/s to the router |
| Onboard NIC | Intel I219-V | Dead: `e1000e` fails to initialize it. Unused |
| iGPU | Intel HD Graphics 530 | Host console; primary display |
| GPU | ASUS ROG Strix RTX 3080 (10 GB) | **Pending install** in the CPU x16 slot, for passthrough to a Linux VM |
| PSU | Corsair RM750 (2019), model RPS0119, part CP-9020195, 750 W, 80+ Gold | **Pending swap** (waiting on its Type 4 24-pin and EPS cables). Uses Corsair Type 4 modular cables only |

Location: network closet next to the router. In-wall cabling elsewhere in the house only supports 100 Mb/s.

## BIOS settings

| Setting | Location | Value | Why |
| --- | --- | --- | --- |
| Intel Virtualization Technology | Advanced → CPU Configuration | Enabled | KVM |
| VT-d | Advanced → System Agent (SA) Configuration | Enabled | IOMMU for PCI passthrough |
| Above 4G Decoding | Advanced → System Agent (SA) Configuration | Enabled | Room to map the GPU's large BARs |
| Primary Display | Advanced → System Agent → Graphics Configuration | CPU Graphics | Host console stays on the iGPU; the host never claims the 3080 |
| iGPU Multi-Monitor | Advanced → System Agent → Graphics Configuration | Enabled | Keeps the iGPU active with a discrete GPU installed |
| Wait for F1 if error | — | Disabled | Boots without a keyboard |
| Restore on AC power loss | — | Power On | Recovers from outages unattended |
| Memory frequency | Ai Tweaker | ~DDR4-3000 | Stable on this CPU's memory controller; DDR4-3600 not attempted |

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

| Root port | Bus | Device | Slot |
| --- | --- | --- | --- |
| `00:01.0` (CPU) | — | Hidden while the slot is empty | CPU x16 slot: RTX 3080 (pending) |
| `00:1b.0` (chipset) | 01 | Empty | Not yet mapped |
| `00:1c.0` (chipset) | 02 | Empty | Not yet mapped |
| `00:1c.4` (chipset) | 03 | Intel X550 (`03:00.0`, `03:00.1`) | Chipset x16 slot (x4 electrical) |
| `00:1d.0` (chipset) | 04 | Empty | Not yet mapped |

IOMMU groups are recorded in [03-gpu-passthrough.md](03-gpu-passthrough.md) once the GPU is installed.

## Future second node (not built)

| Component | Detail |
| --- | --- |
| Motherboard | ASUS ROG Strix X570-I (mini-ITX, one x16 slot) |
| CPU | None yet (AM4) |
| GPU | EVGA RTX 3070 FTW3 (8 GB) |
| RAM | Spare Corsair Vengeance LPX 16 GB DDR4-3000 CL15 (CMK16GX4M1B3000C15) |

AMD-Vi/IOMMU groups to be verified once a CPU is installed.
