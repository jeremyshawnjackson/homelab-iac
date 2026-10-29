# Phase 1: Proxmox VE on bare metal

Status: complete. Host installed and updated, storage and networking configured, Debian cloud-init template created.

## Hardware

See [hardware.md](hardware.md) for current components, BIOS settings and the PCIe/IOMMU layout.

## Network

| Item        | Value                                                                                           |
| ----------- | ----------------------------------------------------------------------------------------------- |
| Home router | AT&T Nokia BGW320-505, defaults (subnet `192.168.1.0/24`, gateway `.254`, DHCP pool `.64–.253`) |
| Host        | `pve.home.arpa`, static `192.168.1.10/24` (outside DHCP pool)                                   |
| DNS         | `1.1.1.1`                                                                                       |
| Bridge      | `vmbr0` with uplink `nic0`; host IP lives on the bridge                                         |
| Reserved    | `.2` NAS, `.10` Proxmox (static, outside the DHCP pool)                                         |

`.home.arpa` is the reserved suffix for home networks (RFC 8375).

## 1. Installer media (Windows workstation)

```powershell
Get-FileHash .\proxmox-ve_9.2-1.iso -Algorithm SHA256   # compare to proxmox.com/downloads
```

Written to USB with Rufus in **DD image mode**.

## 2. Install

- **Terminal UI installer** used. The graphical installer chose a framebuffer resolution smaller than its window on the iGPU, so its buttons were off-screen.
- Target disk: 850 EVO only. Filesystem: **ext4** (not ZFS, because ZFS ARC would compete for scarce RAM).
- Network: values above; "Pin network interface names" left enabled so `nic0` survives kernel/hardware changes. (At install time `nic0` was a temporary Realtek USB adapter; replaced in section 8.)
- Console/web login is `root` (realm Linux PAM). The email address is only for notifications.

## 3. Repositories (no-subscription)

The default enterprise repos return `401 Unauthorized` without a subscription, which caused the boot-time `apt-get update` task to fail (exit code 100). PVE 9 is Debian 13 "Trixie" and uses deb822 `.sources` files, not `.list`.

```bash
ls /etc/apt/sources.list.d/

cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

sed -i '/^Types:/a Enabled: no' /etc/apt/sources.list.d/pve-enterprise.sources
sed -i '/^Types:/a Enabled: no' /etc/apt/sources.list.d/ceph.sources

cat /etc/apt/sources.list.d/*.sources
ls /usr/share/keyrings/proxmox-archive-keyring.gpg

apt update
apt full-upgrade          # not 'apt upgrade': PVE upgrades may add/remove packages
```

Note: the `sed` lines are not idempotent (re-running adds duplicate lines). Replaced by Ansible in Phase 4.

## 4. Kernel update and reboot

```bash
uname -r                  # running kernel
ls /boot/vmlinuz-*        # installed kernels; if a newer one is present, reboot
reboot
uname -r                  # confirm new kernel is running
```

Old kernel kept as a boot-menu fallback.

## 5. Host verification

```bash
pveversion                # pve-manager 9.2.x; kernel 7.0.14-x-pve
nproc                     # 4
grep -c vmx /proc/cpuinfo # 8, since it counts lines and each CPU has 'flags' + 'vmx flags'
lsmod | grep kvm          # kvm_intel + kvm loaded → VT-x usable
pvesm status
cat /etc/network/interfaces
free -h
```

## 6. Bulk storage on the SSHD

Done in GUI: node → Disks → Wipe Disk, then Disks → Directory → Create (ext4, name `bulk`, Add Storage checked).

API/CLI equivalent (device name from `lsblk`):

```bash
pvesh set /nodes/pve/disks/wipedisk --disk /dev/sdX
pvesh create /nodes/pve/disks/directory --device /dev/sdX --name bulk --filesystem ext4 --add_storage 1
```

Inspect and trim content types (no LXC root disks on the slow SSHD):

```bash
systemctl cat mnt-pve-bulk.mount           # systemd mount unit, mounts by UUID
grep -A5 '^dir: bulk' /etc/pve/storage.cfg # note: is_mountpoint 1
pvesm set bulk --content images,iso,vztmpl,backup,snippets
pvesm status
```

`is_mountpoint 1` makes Proxmox mark the storage offline if the disk fails to mount, instead of silently writing to the OS disk.

`images` is enabled on `bulk` for large data disks that tolerate slower storage, such as an LLM model library. VM OS disks go on `local-lvm`.

## 7. SSH key access (Windows workstation)

```powershell
# admin PowerShell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent

# normal PowerShell
ssh-keygen -t ed25519 -C "lab-admin"          # passphrase set
ssh-add $env:USERPROFILE\.ssh\id_ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@192.168.1.10 "cat >> /root/.ssh/authorized_keys"
ssh root@192.168.1.10 hostname                # prints 'pve', no prompt
```

Personal key has a passphrase (unlocked via ssh-agent). CI and automation keys will be separate and scoped.

## 8. NIC replacement and interface pinning

Findings:

- Onboard Intel I219-V is dead: Code 10 in Windows, and under Linux `e1000e` fails to initialize it (`lspci` lists it, `ip link` shows no interface).
- A Realtek USB adapter was used for the install. It linked at 100 Mb/s, but so did the replacement NIC, which isolated the real cause: the in-wall cabling only supports 100 Mb/s. The host now lives in the network closet next to the router and links at 1 Gb/s.
- Replacement: dual-port Intel X550 in a chipset PCIe slot. Supports 1/2.5/5/10G for future upgrades.

Diagnosis, layer by layer:

```bash
lspci -nn | grep -iE 'ethernet|network'     # is the card on the bus?
lspci -k -s 03:00.0                         # driver bound? (ixgbe)
ip -br link                                 # interface names and state
ip link set <iface> up                      # X550 powers down its PHY while DOWN: no link light until up
ethtool <iface> | grep -E 'Speed|Link detected'
```

Repoint the bridge, then pin names by MAC so a slot change or firmware update can't rename the uplink:

```bash
cp /etc/network/interfaces /root/interfaces.bak4
rm /usr/local/lib/systemd/network/50-pmx-nic0.link           # stale pin for the removed USB adapter
pve-network-interface-pinning generate --interface enp3s0f0 --target-name nic0
pve-network-interface-pinning generate --interface enp3s0f1 --target-name nic1
cat /usr/local/lib/systemd/network/*.link                    # [Match] MACAddress= → [Link] Name=
diff /etc/network/interfaces /etc/network/interfaces.new     # tool stages changes; applied at next boot
reboot
ip -br link; grep bridge-ports /etc/network/interfaces
```

Notes:

- `.link` files with a `50-` prefix are applied by systemd-udevd before the default naming policy (`99-default.link`).
- The tool writes `interfaces.new` (applied on reboot) and also updates the firewall and SDN configs.
- Proxmox owns `/etc/network/interfaces` and rewrites the whole file in its own format on any GUI/tool change. Manual stanzas survive only if valid; anything Proxmox must not touch belongs in `/etc/network/interfaces.d/`.
- Rollback if the host comes up offline (from the console): remove the new `.link` files and `interfaces.new`, reboot.

## 9. BIOS settings for headless operation

- "Wait for F1 if error" (keyboard error halt): **Disabled**, so POST completes without a keyboard.
- "Restore on AC power loss": **Power On**, so the host recovers from outages unattended.

## 10. Linux template (Debian 12 cloud image, VM 9000)

Debian 12: a mature cloud image with long-term security support to 2028, and a stable base for the k3s and NVIDIA tooling in later phases.

```bash
cd /mnt/pve/bulk
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2

qm create 9000 --name tpl-debian12 --ostype l26 \
  --memory 2048 --cores 2 --cpu host \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --serial0 socket --vga serial0 \
  --agent enabled=1

qm set 9000 --scsi0 local-lvm:0,import-from=/mnt/pve/bulk/debian-12-genericcloud-amd64.qcow2
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot order=scsi0
qm template 9000
```

- `--cpu host`: fastest, at the cost of live migration across CPU models (irrelevant on one node).
- `virtio` / `virtio-scsi-single`: paravirtual devices, drivers built into Linux.
- `--serial0 socket --vga serial0`: cloud images expect a serial console; view with `qm terminal`.
- `--agent enabled=1`: QEMU guest agent reports IPs to Proxmox/Terraform. Not in the genericcloud image; installed by Ansible in Phase 4.
- `import-from` converts the qcow2 into an LVM-thin volume on the SSD.

Test with a linked clone, then destroy (Terraform creates VMs from here on):

```bash
qm clone 9000 100 --name test-debian          # linked clone: thin overlay on the read-only template
qm set 100 --ciuser admin --sshkeys /root/.ssh/authorized_keys --ipconfig0 ip=dhcp
qm resize 100 scsi0 +8G
qm start 100
qm terminal 100                               # Ctrl+O to exit; cloud-init finished in ~41s
# from Windows: ssh admin@<ip from router device list>
qm stop 100 && qm destroy 100
```

Lessons from the test:

- Windows `type ... | ssh` appended the key with a CRLF line ending. Fixed with `sed -i --follow-symlinks 's/\r$//' /root/.ssh/authorized_keys` (`--follow-symlinks` matters: the file is a symlink into `/etc/pve/priv/`). Check with `cat -A`.
- Passing the whole `authorized_keys` also gave the clone the host's `root@pve` key. Terraform will pass only the intended public keys.
- Proxmox enables cloud-init package upgrades by default (`ciupgrade`), adding ~30s per VM to provisioning time.
- Without the guest agent, Proxmox can't see guest IPs; the router device list (Proxmox MAC prefix `bc:24:11`) was used instead.

## Resulting storage layout

| Storage     | Type    | Disk     | Size     | Content                                                   |
| ----------- | ------- | -------- | -------- | --------------------------------------------------------- |
| `local`     | dir     | 850 EVO  | ~66 GiB  | ISO, templates, backups (default)                         |
| `local-lvm` | lvmthin | 850 EVO  | ~137 GiB | VM disks                                                  |
| `bulk`      | dir     | FireCuda | ~1.8 TiB | images (large data disks), ISO, templates, backups, snippets |
