# Phase 3: GPU hardware validation and passthrough

Status: complete. The RTX 3080 is passed through to a Linux VM with VFIO, runs on NVIDIA driver 615 / CUDA 13.4, and held a 15-minute sustained LLM load at a flat 65 °C with no GPU faults or host instability.

Current hardware state: [hardware.md](hardware.md).

## Results

| Check | Result |
| --- | --- |
| RTX 3080 in its own IOMMU group | Group 2: GPU video + audio + CPU root port only; no ACS override needed |
| Host never touches the GPU | Both functions bound to `vfio-pci` at boot |
| Visible in a Linux VM | Yes, at `01:00.0` / `01:00.1` |
| Driver in the VM | 615.71.10 (NVIDIA repository), CUDA 13.4, open kernel module |
| Sustained load (40 generations, ~15 min) | Flat 65 °C, ~270 W at a 1650 MHz clock cap; no Xid errors, no VM or GPU resets |
| Inference speed (Llama 3.1 8B, Q4) | 116 tokens/s at the 1650 MHz cap (119.5 stock) |
| Open items | PCIe link at x8; Ollama memory leak (see section 10) |

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| GPUs per node | One for now | The CPU x16 slot is the only slot with its own IOMMU group verified; avoids an x1 riser and a possible ACS override |
| First GPU node | Existing Proxmox host + RTX 3080 | No new board needed; LLM inference needs little CPU or PCIe bandwidth |
| Second GPU (RTX 3070) | Undecided | Options: a second node (ROG Strix X570-I in a FormD T1 case, with an SFX PSU), a second GPU on this node via an x1 riser, or stay single-GPU |
| PSU | Corsair RM750 (2019), replacing a CX750M | Gold vs Bronze efficiency for a 24/7 host, fully modular, better margin for 3080 transients |
| RAM | G.Skill Trident Z Neo 2×16 GB | Available on hand |
| GPU power tuning | Core clock capped at 1650 MHz | −27% power for −2.8% speed; steadier than a power limit (section 9) |

## 1. Identify the hardware

```bash
dmidecode -t baseboard | grep -E 'Manufacturer|Product|Version'   # ASUS Z170M-PLUS
dmidecode -t bios | grep -E 'Version|Release'                     # 3805, 2018-05-16
dmidecode -t memory | grep -E 'Locator|Size|Speed' | grep -v Bank # slots and speed
lspci -tv                                                         # root ports and buses
```

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

- Installed spare G.Skill Trident Z Neo 2×16 GB in DIMM_A2 and DIMM_B2 (ASUS's two-DIMM slots). The old Corsair 16 GB stick is set aside for the future second node.
- The board kept the previous ~DDR4-3000 setting; the kit trained at DDR4-2944, CL16-19-19-39.
- Memtest86+ 7.20 from the GRUB menu: **19 passes, 0 errors** over ~22 hours.
- DDR4-3600 not attempted: the i5-6600 is officially rated for DDR4-2133.

```bash
free -h    # 31Gi total, 28Gi available
```

## 4. Power

- RM750 (2019): model RPS0119, part CP-9020195, 750 W, Gold. Uses **Corsair Type 4** modular cables.
- Replaced a Corsair CX750M (Bronze, semi-modular, with fixed 24-pin and CPU cables). The RM750 uses its own Type 4 cables throughout; the CX750M is kept as a spare.
- GPU fed by **three separate PCIe cables**, one per 8-pin socket on the Strix (no daisy-chained second plug).

## 5. Install the RTX 3080

- ASUS ROG Strix RTX 3080 in the CPU x16 slot; monitor stays on the motherboard's video output (host console on the iGPU).
- Adding the GPU renumbered the chipset buses: the X550 moved from bus `03` to `04`. Interface names are pinned by MAC, so `nic0` stayed `nic0` and the host stayed online.

PCIe link:

```bash
lspci -vv -s 01:00.0 | grep -E 'LnkCap|LnkSta'
# LnkCap: Speed 8GT/s, Width x16
# LnkSta: Speed 2.5GT/s (downgraded), Width x8 (downgraded)
```

Reduced speed at idle is normal power saving. Width stayed **x8 under full load** (`pcie.link.width.current = 8` in `nvidia-smi`) and after one reseat, which points to the slot, the board or the card's contacts. Impact on inference is small (PCIe 3.0 x8 ≈ 7.9 GB/s; mainly slower model loading). Open item: clean the slot and reseat again.

## 6. IOMMU groups

```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
  g=${d#*/iommu_groups/}; g=${g%%/*}
  printf 'group %-3s ' "$g"; lspci -nns "${d##*/}"
done | sort -V
```

```
group 2   00:01.0 PCI bridge: Intel 6th-10th Gen Core Processor PCIe Controller (x16) [8086:1901]
group 2   01:00.0 VGA compatible controller: NVIDIA GA102 [GeForce RTX 3080] [10de:2206]
group 2   01:00.1 Audio device: NVIDIA GA102 High Definition Audio Controller [10de:1aef]
```

The GPU shares its group only with its own CPU root port, the ideal layout. Every chipset device (USB, SATA, NICs) is in a separate group.

## 7. Bind the GPU to vfio-pci

Before binding, the host's `nouveau` driver had claimed the card. `vfio-pci` is bound by device ID and loaded ahead of `nouveau`, and the host NVIDIA drivers are blacklisted:

```bash
cat > /etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=10de:2206,10de:1aef
softdep nouveau pre: vfio-pci
EOF

cat > /etc/modprobe.d/blacklist-nvidia.conf <<'EOF'
blacklist nouveau
blacklist nvidiafb
blacklist nvidia
EOF

cat >> /etc/modules <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF

update-initramfs -u -k all    # drivers can load from the initramfs, so it must carry these settings
reboot
```

Verify:

```bash
lspci -k -s 01:00.0    # Kernel driver in use: vfio-pci
lspci -k -s 01:00.1    # Kernel driver in use: vfio-pci
```

`Kernel modules:` lists drivers that could bind, not drivers that are loaded. `vfio_virqfd` is no longer a separate module in current kernels.

## 8. Test VM

A disposable VM built with `qm` to prove passthrough; the real GPU node is built by Terraform in Phase 4.

```bash
grep jeremy-lab /root/.ssh/authorized_keys > /root/admin.pub   # only the admin key, not root@pve's

qm clone 9000 150 --name gpu-test --full
qm set 150 --machine q35 --bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 150 --memory 8192 --balloon 0 --cores 4 --cpu host
qm set 150 --hostpci0 0000:01:00,pcie=1
qm set 150 --delete ide2
qm set 150 --scsi1 local-lvm:cloudinit
qm resize 150 scsi0 40G
qm set 150 --ciuser admin --sshkeys /root/admin.pub \
  --ipconfig0 ip=192.168.1.21/24,gw=192.168.1.254 --nameserver 1.1.1.1
qm start 150
```

| Setting | Why |
| --- | --- |
| `q35`, `pcie=1` | Real PCIe topology in the guest, which modern NVIDIA drivers expect |
| OVMF, `pre-enrolled-keys=0` | UEFI firmware recommended for GPU passthrough; Secure Boot off so the unsigned NVIDIA module can load |
| `balloon 0` | Passthrough VM memory is pinned (the GPU can DMA into any of it), so ballooning doesn't apply |
| `hostpci0: 0000:01:00` | No function number passes both functions (video + audio) together |
| Cloud-init drive on `scsi1` | See below |

**Cloud-init drive on q35.** The first boot reached a `localhost login:` prompt with no network: cloud-init hadn't applied the hostname, IP or SSH key. Template 9000 puts the cloud-init drive on `ide2`, which worked on the `i440fx` machine type but wasn't seen by Debian's cloud kernel once the VM was switched to `q35`. Moving the drive to `scsi1` (virtio-SCSI, the same controller as the boot disk) fixed it: the prompt became `gpu-test login:` and SSH worked. q35 VMs need their cloud-init drive on SCSI.

## 9. Driver and power tuning

**Driver.** Debian 12's own `nvidia-driver` (535, from `non-free`) loaded and `nvidia-smi` worked, but Ollama logged `NVIDIA driver too old ... required_driver="550 or newer"` and fell back to its Vulkan backend. The driver was replaced with NVIDIA's Debian 12 repository:

```bash
sudo apt purge -y 'nvidia-*' 'libnvidia-*'
sudo apt autoremove -y
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y linux-headers-cloud-amd64 cuda-drivers   # DKMS builds the module against the cloud kernel
sudo reboot
nvidia-smi    # 615.71.10, CUDA 13.4
```

Ollama then reported `library=CUDA compute=8.6`. The NVIDIA repository upgrades the driver on every `apt upgrade`, so the Phase 5 GPU node pins a known-good version.

**Power tuning.** Same prompt, five generations per setting (~2 minutes each), Llama 3.1 8B:

| Setting | Eval rate (tok/s) | Power (W) | Temp at ~2 min | Speed vs stock | Power vs stock | tok/s per 100 W |
| --- | --- | --- | --- | --- | --- | --- |
| Stock (370 W limit) | 119.5 | ~368 | 66 °C | — | — | 32.5 |
| Clock cap 1800 MHz | 118.2 | ~314 | 63 °C | −1.1% | −15% | 37.6 |
| **Clock cap 1650 MHz** | **116.2** | **~267** | **62 °C** | **−2.8%** | **−27%** | **43.5** |
| Power limit 280 W | 117.3 | ~279 | 63 °C | −1.8% | −24% | 42.0 |

```bash
sudo nvidia-smi -lgc 210,1650    # chosen setting; reset with: sudo nvidia-smi -rgc
```

- At stock the card sat at its 370 W limit throughout.
- The Linux driver doesn't expose voltage-curve editing; a clock cap is the closest equivalent to an undervolt, because the GPU runs lower on its voltage/frequency curve.
- Under the 280 W power limit the clock moved between 1680 and 1710 MHz and jumped to 1950 MHz at the end of each job; the clock cap held a flat 1650 MHz.
- Cutting core clock ~15% cost under 3% of speed: token generation is bound by memory bandwidth, not compute.
- `prompt eval rate` was ignored: the ~20-token prompt is too short to measure prompt processing.
- The clock cap is a runtime setting and doesn't survive a reboot; Phase 5 applies it at boot on the GPU node.

## 10. Sustained load test

```bash
P="Write a detailed 1500-word technical essay on how data centers are cooled."
sudo nvidia-smi -lgc 210,1650
for i in $(seq 1 40); do ollama run llama3.1:8b "$P" > /dev/null; echo "run $i done"; done
```

Monitored with:

```bash
nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu,pcie.link.gen.current,pcie.link.width.current --format=csv -l 5
```

- Temperature levelled off at **65 °C**, ~270 W, 1650 MHz, 92–95% utilization.
- No Xid messages in the guest (`dmesg | grep -i xid`); only the driver load line.
- No `vfio-pci` resets on the host during the run (`journalctl -k -g "vfio-pci.*reset" -o short-iso`).

**Ollama out-of-memory.** One request failed with `Error: Post "http://127.0.0.1:11434/api/generate": EOF` at run 39, in this run and in an earlier run on driver 535 and the Vulkan backend at 370 W. Failing at the same point across different drivers, backends and power levels ruled out the GPU and PSU. The guest kernel log showed the cause:

```
Out of memory: Killed process 1542 (llama-server) ... anon-rss:7261116kB, file-rss:64636kB
```

- `llama-server` (Ollama's model process) had grown to ~7.3 GB of anonymous memory in the 7.7 GB VM, with no swap.
- The model weights are on the GPU and memory-mapped (`file-rss` 64 MB), so the anonymous memory is not the weights: it grows with each request.
- The journal showed `llama-server` restarting about every 13 minutes, the time it took to fill the VM's memory.

Conclusion: a memory leak in this Ollama version, not a hardware fault. Follow-ups: memory limits and a pinned Ollama version in Phase 5 (Kubernetes restarts the process cleanly at its limit), an `OOMKilled`/restart alert and memory graph in Phase 6, and at least 12 GB RAM for the GPU node in Phase 4.

## Open items

| Item | Next step |
| --- | --- |
| PCIe link at x8 under load | Clean the slot and reseat; low impact if it stays |
| Ollama `llama-server` memory leak | Phase 5: memory limit, pinned version, re-test; compare with vLLM |
| Clock cap is not persistent | Phase 5: apply at boot on the GPU node |
| Driver auto-upgrades from the NVIDIA repository | Phase 5: pin the driver version |

## Lessons

- **Confirm the hardware model from the system, not memory.** `dmidecode` corrected the board model before any BIOS or slot planning.
- **VT-d is often off by default.** Check for `DMAR:` lines and `/sys/class/iommu/`, not just the generic `iommu:` messages.
- **Modular PSU cables are PSU-specific.** Identify the cable type from the PSU label; never reuse another PSU's modular cables, even when the plugs fit.
- **Pin interface names before changing hardware.** Adding the GPU renumbered the PCIe buses; MAC-pinned names kept the host online.
- **Changing the machine type changes the virtual hardware.** The cloud-init drive that worked on `i440fx` was invisible on `q35`.
- **Read application logs, not just `nvidia-smi`.** The GPU looked busy on driver 535, but Ollama was on a fallback backend.
- **Isolate one variable at a time.** The same failure at the same run across two drivers and power levels pointed away from hardware; the kernel log confirmed an OOM kill.
