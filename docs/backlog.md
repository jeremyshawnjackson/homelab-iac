# Backlog

Planned work beyond the current phases.

| Item | Notes |
| --- | --- |
| Second GPU (EVGA RTX 3070, 8 GB) | Undecided: a second node (ASUS ROG Strix X570-I in the FormD T1 case; needs a CPU and an SFX/SFX-L PSU, since the T1 doesn't take ATX units like the CX750M), a second GPU on this host via an x1 riser (check that slot's IOMMU group), or stay single-GPU |
| Jellyfin | Run alongside the existing Plex server on the NAS, then cut over |
| DNS / ad blocking | Self-hosted resolver on the cluster |
| Automated Proxmox install | Proxmox `answer.toml` so the bare-metal install is reproducible too |
| Trusted TLS for the Proxmox API | Replace the provider's `insecure = true` with a trusted certificate |
