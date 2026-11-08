# Backlog

Planned work beyond the current phases.

| Item | Notes |
| --- | --- |
| Second GPU (EVGA RTX 3070, 8 GB) | Undecided: a second node (ASUS ROG Strix X570-I in the FormD T1 case; needs a CPU and an SFX/SFX-L PSU, since the T1 doesn't take ATX units like the CX750M), a second GPU on this host via an x1 riser (check that slot's IOMMU group), or stay single-GPU |
| Jellyfin | Run alongside the existing Plex server on the NAS, then cut over |
| DNS / ad blocking | Self-hosted resolver on the cluster |
| Automated Proxmox install | Proxmox `answer.toml` so the bare-metal install is reproducible too |
| Trusted TLS for the Proxmox API | Replace the provider's `insecure = true` with a trusted certificate |
| SSH certificates | A rebuilt VM on a reused IP presents a new host key and is refused until a human prunes `known_hosts`. Host certificates signed by a lab CA make rebuilds trusted automatically |
| Trusted TLS and DNS inside the cluster | Argo CD and other UIs are reachable only through `kubectl port-forward`. Needs a lab resolver and a certificate issuer before ingress hostnames are worth wiring up |
| Scheduled template rebuilds | Template 9000 is frozen at the patch level it was built with, so a rebuilt node comes back on an older kernel than its longer-lived neighbours |
