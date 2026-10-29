# Phase 3: GPU hardware validation and passthrough

Status: in progress. Host hardware validated for passthrough (VT-d, interrupt remapping, 32 GB RAM); waiting on PSU cables before installing the RTX 3080.

**Gate for the rest of the plan:** `nvidia-smi` inside a Linux VM shows the RTX 3080, and a 15-minute sustained GPU load runs with stable temperatures and no host instability.

Current hardware state: [hardware.md](hardware.md).

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| GPUs per node | One | Avoids x1-riser slots, shared IOMMU groups (ACS override) and splitting power across PSUs |
| First GPU node | Existing Proxmox host + RTX 3080 | No new board needed; LLM inference needs little CPU or PCIe bandwidth |
| Second GPU node | ROG Strix X570-I + RTX 3070, later | Needs a CPU, case and PSU; outside the current budget |
| PSU | Corsair RM750 (2019) | ~500 W sustained for one Strix 3080 + i5-6600; quality unit. GPU power-limited for inference (see below) |
| RAM | G.Skill Trident Z Neo 2×16 GB found on hand | Matched kit; DDR4 retail prices were near a 3-month high (median ~$8/GB), so buying was deferred |
| Budget | ~$200 | Spent so far: Type 4 cable kit only |

## 1. Identify the hardware

```bash
dmidecode -t baseboard | grep -E 'Manufacturer|Product|Version'   # ASUS Z170M-PLUS
dmidecode -t bios | grep -E 'Version|Release'                     # 3805, 2018-05-16
dmidecode -t memory | grep -E 'Locator|Size|Speed' | grep -v Bank # slots and speed
lspci -tv                                                         # root ports and buses
```

Finding: the board had been recorded as an H170M-Plus. `lspci` reported a Z170 LPC controller, and `dmidecode` confirmed a Z170M-PLUS. The model matters for slot layout, BIOS menus and RAM support.

Finding: RAM was a single 16 GB stick (single channel).

## 2. Enable VT-d

Before: no IOMMU.

```bash
journalctl -k -b | grep -i -e DMAR -e IOMMU   # only generic "iommu:" lines, no DMAR
ls /sys/class/iommu/                          # empty
```

The generic `iommu:` lines print on every boot; without `DMAR:` lines and a `dmar*` entry, the firmware isn't exposing VT-d.

BIOS changes (ASUS UEFI, F7 Advanced Mode):

- Advanced → System Agent (SA) Configuration → VT-d: **Enabled**
- Advanced → System Agent (SA) Configuration → Above 4G Decoding: **Enabled**
- Advanced → System Agent → Graphics Configuration → Primary Display: **CPU Graphics**
- Advanced → System Agent → Graphics Configuration → iGPU Multi-Monitor: **Enabled**

After:

```bash
dmesg | grep -e DMAR -e IOMMU    # ACPI DMAR table; dmar0, dmar1; Intel(R) Virtualization Technology for Directed I/O
dmesg | grep -i remapping        # Enabled IRQ remapping in x2apic mode
ls /sys/class/iommu/             # dmar0 dmar1
```

No kernel parameter was needed: the Proxmox kernel turns the Intel IOMMU on once the firmware exposes it.

## 3. RAM upgrade and validation

- Installed G.Skill Trident Z Neo 2×16 GB in DIMM_A2 and DIMM_B2 (ASUS's two-DIMM slots). The old Corsair 16 GB stick is set aside for the future second node rather than mixed with a different kit.
- The board kept the previous ~DDR4-3000 setting; the kit trained at DDR4-2944, CL16-19-19-39.
- Memtest86+ 7.20 from the GRUB menu (non-serial entry): **19 passes, 0 errors** over ~22 hours. One pass of 32 GB takes ~31 minutes.
- DDR4-3600 not attempted: the i5-6600 is officially rated for DDR4-2133, and the extra speed doesn't matter for this workload.

```bash
free -h    # 31Gi total, 28Gi available
```

Note: Memtest86+ has its own USB stack and may not see some keyboards (USB 3 ports, hubs, wireless). A hard reset during Memtest is safe: it runs entirely from RAM and no filesystem is mounted.

## 4. Power

- RM750 (2019): model RPS0119, part CP-9020195, 750 W, Gold. Uses **Corsair Type 4** modular cables.
- Modular cables are not interchangeable between PSU models or Corsair cable types: the PSU-side pinouts differ even when the plugs fit. Wrong cables can destroy components.
- PSU sockets: 24-pin ATX as 18-pin + 10-pin; five shared 8-pin "6+2 PCIe & 4+4 CPU" sockets; "Peripheral & SATA" 6-pin sockets.
- Cabling plan: 1× 24-pin, 1× EPS (CPU), **3× separate PCIe cables** to the Strix's three 8-pin sockets (no daisy-chained second plug), RM750 SATA power cable for both drives.
- GPU power limit for inference (after passthrough): `nvidia-smi -pl 250` to `280`. Little inference speed lost; less heat in the closet and smaller transients.

## 5. Install the RTX 3080 (pending)

- [ ] Swap in the RM750 with its Type 4 cables (24-pin, EPS, 3× PCIe, SATA power)
- [ ] Install the Strix in the CPU x16 slot; confirm it doesn't cover the X550's slot
- [ ] Monitor stays on the motherboard's video output

## 6. IOMMU groups (pending)

```bash
lspci -nn | grep -i nvidia
lspci -vv -s 01:00.0 | grep -E 'LnkCap|LnkSta'
for d in /sys/kernel/iommu_groups/*/devices/*; do
  g=${d#*/iommu_groups/}; g=${g%%/*}
  printf 'group %-3s ' "$g"; lspci -nns "${d##*/}"
done | sort -V
```

Pass: the 3080's VGA and audio functions are in a group with nothing else except, possibly, the `00:01.0` root port.

## 7. Bind to vfio-pci, test VM, nvidia-smi (pending)

## 8. Sustained load test (pending)

## Lessons

- **Confirm the hardware model from the system, not memory.** `dmidecode` corrected the board model before any BIOS or slot planning.
- **VT-d is often off by default.** Check for `DMAR:` lines and `/sys/class/iommu/`, not just the generic `iommu:` messages.
- **Check current prices before planning purchases.** DRAM prices were far above older estimates (~$130 for one 16 GB stick); the plan was re-scoped instead.
- **Modular PSU cables are PSU-specific.** Identify the cable type from the PSU label before buying.
