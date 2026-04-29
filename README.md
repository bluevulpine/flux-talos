<div align="center">

### Bluevulpine's Home Operations Repository 🦊

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>

---

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes cluster using tools like [Kubernetes](https://kubernetes.io/), [Flux](https://github.com/fluxcd/flux2), [Renovate](https://github.com/renovatebot/renovate), and [GitHub Actions](https://github.com/features/actions).

The baseline of this configuration starts from from onedr0p's [cluster-template](https://github.com/onedr0p/cluster-template). Inspiration for further workloads to run in the cluster and how to provision their kustomizations extends from many other related home-ops projects in the community.

---

## ⛵ Kubernetes

[Talos](https://www.talos.dev) is the linux distribution running kubernetes on my nodes. I have so far been happy with the results. I'd previously tried provisioning k3s on top of ubuntu with various ansible scripts to assist with the setup. Talos seems like less overhead to maintain and update.

I've tried several cluster storage paradigms over time — mayastor, rook-ceph, and others. Currently the cluster runs Longhorn for replicated persistent volumes alongside OpenEBS for local hostpath storage, and NFS via democratic-csi for storage backed by TrueNAS. MinIO handles object storage for observability components like Loki and Thanos.

### 🏗️ Core Components

- [actions-runner-controller](https://github.com/actions/actions-runner-controller): Self-hosted Github runners.
- [cert-manager](https://github.com/cert-manager/cert-manager): Creates SSL certificates utilizing Let's Encrypt and Cloudflare DNS.
- [cilium](https://github.com/cilium/cilium): Internal Kubernetes container networking interface.
- [cloudflare-tunnel](https://github.com/cloudflare/cloudflared): Enables Cloudflare secure access to certain ingresses.
- [external-dns](https://github.com/kubernetes-sigs/external-dns): Automatically syncs ingress DNS records to a DNS provider.
- [envoy-gateway](https://gateway.envoyproxy.io/): Kubernetes Gateway API implementation using Envoy proxy.
- [external-secrets](https://github.com/external-secrets/external-secrets): Managed Kubernetes secrets using Bitwarden Secrets Manager via the [bitwarden-sdk-server](https://github.com/external-secrets/bitwarden-sdk-server).
- [sops](https://github.com/getsops/sops): Managed secrets for Kubernetes which are commited to Git.
- [spegel](https://github.com/spegel-org/spegel): Stateless cluster local OCI registry mirror.
- [volsync](https://github.com/backube/volsync): Backup and recovery of persistent volume claims.

### GitOps

[Flux](https://github.com/fluxcd/flux2) watches the apps in my [kubernetes](./kubernetes/) folder and makes changes to the cluster based on the state of my Git repository.

[Renovate](https://github.com/renovatebot/renovate) watches my **entire** repository looking for dependency updates. When they are found, patch changes are automatically applied. For more major changes, a PR is automatically created. Flux applies the changes to my cluster after commits to main.


```sh
📁 kubernetes
├── 📁 apps           # applications
├── 📁 bootstrap      # bootstrap procedures
├── 📁 flux           # core flux configuration
└── 📁 templates      # re-useable components
```

### Networking

Cilium is configured to use direct routing (no VXLAN) — all nodes run on the same subnet (`10.0.10.0/24`). Workloads that need a stable, directly-routable IP get one via Cilium's LB-IPAM from the `172.16.8.0/24` pool. Each assigned address is advertised as a `/32` host route over BGP (cluster ASN `65512`, peering with the UniFi router at `10.0.10.1`, ASN `65510`). The UniFi router picks up these routes and makes the addresses reachable across the network — the `172.16.8.x` range is otherwise unallocated by DHCP and exists solely for this purpose.

Tailscale Operator is also deployed, enabling direct Tailscale connectivity for select pods and services.

---

## ☁️ Cloud Dependencies

While most of my infrastructure and workloads are self-hosted I do rely upon the cloud for certain key parts of my setup. This saves me from having to worry about three things. (1) Dealing with chicken/egg scenarios, (2) services I critically need whether my cluster is online or not and (3) The "hit by a bus factor" - what happens to critical apps (e.g. Email, Password Manager, Photos) that my family relies on when I no longer around.


| Service                                   | Use                                                                                    | Cost            |
|-------------------------------------------|----------------------------------------------------------------------------------------|-----------------|
| [Bitwarden](https://bitwarden.com/)       | Family password manager, Secrets with [External Secrets](https://external-secrets.io/) | ~$40/yr         |
| [Cloudflare](https://www.cloudflare.com/) | Several Domains and S3                                                                 | ~$100/yr        |
| [GitHub](https://github.com/)             | Hosting this repository and CI/CD. Pro subscription.                                   | ~$48/yr         |
| [Fastmail](https://fastmail.com/)         | Email hosting for 2 users                                                              | ~$100/yr        |
| [NextDNS](https://nextdns.io/)            | Network-wide DNS filtering (basic plan)                                                | ~$20/yr         |
| [Pushover](https://pushover.net/)         | Kubernetes Alerts and application notifications                                        | $5 OTP          |

---

## 🌐 DNS

In my cluster there are multiple [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) instances deployed. One uses the [ExternalDNS webhook provider for UniFi](https://github.com/kashalls/external-dns-unifi-webhook) to sync DNS records to my UniFi router. Another syncs records to Cloudflare only for ingresses with class `external` and the annotation `external-dns.alpha.kubernetes.io/target`. [k8s-gateway](https://github.com/ori-edge/k8s_gateway) handles in-cluster DNS resolution for services and ingresses.

Local clients use [NextDNS](https://nextdns.io) as their upstream resolver (via the UniFi router), providing network-wide ad/tracker blocking.

---

## 🔧 Hardware

| Device                      | Count | OS Disk Size | Data Disk Size               | Ram  | Operating System | Purpose                          |
|-----------------------------|-------|--------------|------------------------------|------|------------------|----------------------------------|
| Gmktec M5 Pro               | 3     | 1TB SSD      | 2TB NVMe                     | 64GB | Talos            | Kubernetes Workers (brokkr01-03) |
| RasPi 4                     | 3     | 512GB SSD    | -                            | 8GB  | Talos            | Kubernetes Control Plane         |
| RasPi 4                     | 1     | 512GB SSD    | -                            | 8GB  | Talos            | Kubernetes Worker                |
| RasPi 3                     | 1     | 32GB  SD     | -                            | 1GB  | DietPi           | (repurposed?)           |
| RasPi 5                     | 1     | 128GB SD     | -                            | 8GB  | HAOS             | Home Assistant          |
| Supermicro 846 & X9dri-f    | 1     | 2x 512GB SSD | 10x16TB ZFS (mirrored vdevs) | 64GB | TrueNAS Scale    | NFS + Backup Server     |
| UniFi UDM SE                | 1     | -            | 1x12TB HDD                   | -    | -                | Router & NVR            |
| UniFi USW-Enterprise-24-PoE | 1     | -            | -                            | -    | -                | 2.5Gb PoE Switch        |
| UniFi USP PDU Pro           | 1     | -            | -                            | -    | -                | PDU                     |
| APC SMT1500RM2U             | 1     | -            | -                            | -    | -                | UPS                     |

---

## ⭐ Stargazers

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=bluevulpine/flux-talos&type=Date)](https://star-history.com/#bluevulpine/flux-talos&Date)

</div>

---

## 🤝 Gratitude and Thanks

Thanks to all the people who donate their time to the [Home Operations](https://discord.gg/home-operations) Discord community. Be sure to check out [kubesearch.dev](https://kubesearch.dev/) for ideas on how to deploy applications or get ideas on what you could deploy.
