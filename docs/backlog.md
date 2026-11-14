# Backlog

Planned work beyond the current phases.

| Item | Notes |
| --- | --- |
| Second GPU (EVGA RTX 3070, 8 GB) | Undecided: a second node (ASUS ROG Strix X570-I in the FormD T1 case; needs a CPU and an SFX/SFX-L PSU, since the T1 doesn't take ATX units like the CX750M), a second GPU on this host via an x1 riser (check that slot's IOMMU group), or stay single-GPU |
| Jellyfin | Run alongside the existing Plex server on the NAS, then cut over |
| Automated Proxmox install | Proxmox `answer.toml` so the bare-metal install is reproducible too |
| Trusted TLS for the Proxmox API | Replace the provider's `insecure = true` with a trusted certificate |
| SSH certificates | A rebuilt VM on a reused IP presents a new host key and is refused until a human prunes `known_hosts`. Host certificates signed by a lab CA make rebuilds trusted automatically |
| Trusted TLS inside the cluster | Argo CD and other UIs are reachable only through `kubectl port-forward`. The lab resolver arrives in Phase 6, which leaves a certificate issuer as the remaining blocker on ingress hostnames. cert-manager with a DNS-01 issuer keeps nothing exposed publicly |
| Scheduled template rebuilds | Template 9000 is frozen at the patch level it was built with, so a rebuilt node comes back on an older kernel than its longer-lived neighbours |
| Remote access over Tailscale | Reaches the lab without publishing a service endpoint, which a public tunnel would. Consistent with keeping the live cluster out of a public index |
| OIDC single sign-on | Authentik or Keycloak behind the ingress, with forward-auth. Also replaces Argo CD's admin password with real logins |
| Short-lived credentials for secret decryption | The age identity in the cluster is a long-lived key that decrypts every secret in the repository's history. Vault or OpenBao with the Kubernetes auth method would exchange a pod's ServiceAccount token for a scoped, revocable, audited credential instead, which shrinks the blast radius of a compromised repo-server. The cost is a stateful service whose unseal keys become the new stored root, so this waits until observability can report on it |
| Registry pull-through cache | A local mirror so a node rebuild stops re-pulling every image over the uplink, and image provenance has one place to be checked |
| Orchestrated lab power-down | `ansible/power.yml` moves the relay and refuses to cut a host that is still drawing power, but the graceful half is still manual: shutting the VMs down and then the host. Worth automating as one playbook, with the plug's power meter as the gate between the two halves |
| Wall-power metering in Prometheus | The plug reports watts, volts and a kWh counter over its local API. Scraped in Phase 6 it gives the host's real idle and under-load draw, a cost figure, and two alerts worth having: draw collapsing to standby (unexpected power loss) and draw staying at load level while the cluster reports idle (a runaway job, the Phase 3 Ollama leak class) |
| Periodic memory verification | This platform has no ECC, so a failing DIMM corrupts data with nothing in SMART, EDAC or the kernel log to show for it. A scheduled write-verify pass over host memory, reported through the Phase 6 metrics stack, turns a silent fault into an alert |
