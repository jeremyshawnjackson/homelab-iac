# Backlog

Planned work beyond the current phases.

| Item | Notes |
| --- | --- |
| Second GPU node | ASUS ROG Strix X570-I + EVGA RTX 3070 (8 GB). Needs a CPU, a case that fits a 3-slot card, and a PSU. Verify AMD-Vi/IOMMU groups once built |
| Jellyfin | Run alongside the existing Plex server on the NAS, then cut over |
| DNS / ad blocking | Self-hosted resolver on the cluster |
| Automated Proxmox install | Proxmox `answer.toml` so the bare-metal install is reproducible too |
| Trusted TLS for the Proxmox API | Replace the provider's `insecure = true` with a trusted certificate |
