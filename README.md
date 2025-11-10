<div align="center">

### Bluevulpine's Home Operations Repository 🦊

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>

---

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes cluster using tools like [Ansible](https://www.ansible.com/), [Kubernetes](https://kubernetes.io/), [Flux](https://github.com/fluxcd/flux2), [Renovate](https://github.com/renovatebot/renovate), and [GitHub Actions](https://github.com/features/actions).

The baseline of this configuration starts from from onedr0p's [cluster-template](https://github.com/onedr0p/cluster-template). Inspiration for further workloads to run in the cluster and how to provision their kustomizations extends from many other related home-ops projects in the community.

---

## ⛵ Kubernetes

[Talos](https://www.talos.dev) is the linux distribution running kubernetes on my nodes. I have so far been happy with the results. I'd previously tried provisioning k3s on top of ubuntu with various ansible scripts to assist with the setup. Talos seems like less overhead to maintain and update.

I've tried some hyper-converged cluster storage paradigms, using mayastor, longhorn, or rook-ceph. Currently, I've moved my primary workers and control-plane nodes to VMs on a Proxmox cluster, and am using NFS storage for persistent volumes and MinIO for object storage (used by observability stack components like Loki and Thanos).

### 🏗️ Core Components

- [actions-runner-controller](https://github.com/actions/actions-runner-controller): Self-hosted Github runners.
- [cert-manager](https://github.com/cert-manager/cert-manager): Creates SSL certificates utilizing Let's Encrypt and Cloudflare DNS.
- [cilium](https://github.com/cilium/cilium): Internal Kubernetes container networking interface.
- [cloudflare-tunnel](https://github.com/cloudflare/cloudflared): Enables Cloudflare secure access to certain ingresses.
- [external-dns](https://github.com/kubernetes-sigs/external-dns): Automatically syncs ingress DNS records to a DNS provider.
- [external-secrets](https://github.com/external-secrets/external-secrets): Managed Kubernetes secrets using [Bitwarden Secrets Manager Cache](https://github.com/rippleFCL/bws-cache). BWSC seems a bit unstable, so I have a cronjob set to restart it daily.
- [ingress-nginx](https://github.com/kubernetes/ingress-nginx): Kubernetes ingress controller using NGINX as a reverse proxy and load balancer.
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

Cilium is configured to use direct mode instead of vxlan tunneling. All nodes must be on the same subnet with each other. As a concequence to this choice, I've not had luck placing a worker node in a different subnet (for example, creating a single tainted worker to host untrusted or IOT-related workloads in a more-secure VLAN). Trying to convert in-place to encapsulation using VXLAN nearly immediately broke cluster networking. More science is required. 🧫

I have tailscale's operator running, which potentially could also help solve the problem.

---

## ☁️ Cloud Dependencies

While most of my infrastructure and workloads are self-hosted I do rely upon the cloud for certain key parts of my setup. This saves me from having to worry about three things. (1) Dealing with chicken/egg scenarios, (2) services I critically need whether my cluster is online or not and (3) The "hit by a bus factor" - what happens to critical apps (e.g. Email, Password Manager, Photos) that my family relies on when I no longer around.


| Service                                   | Use                                                                                    | Cost            |
|-------------------------------------------|----------------------------------------------------------------------------------------|-----------------|
| [Bitwarden](https://bitwarden.com/)       | Family password manager, Secrets with [External Secrets](https://external-secrets.io/) | ~$40/yr         |
| [Cloudflare](https://www.cloudflare.com/) | Several Domains and S3                                                                 | ~$100/yr        |
| [GitHub](https://github.com/)             | Hosting this repository and CI/CD. Pro subscription.                                   | ~$48/yr         |
| [Fastmail](https://fastmail.com/)         | Email hosting for 2 users                                                              | ~$100/yr        |
| [Pushover](https://pushover.net/)         | Kubernetes Alerts and application notifications                                        | $5 OTP          |
|                                           |                                                                                        | Total: ~$xyz/mo |

---

## 🌐 DNS

In my cluster there are multiple [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) instances deployed. One is deployed with the [ExternalDNS webhook provider for UniFi](https://github.com/kashalls/external-dns-unifi-webhook) which syncs DNS records to my UniFi router. Another does the same to a [PiHole](https://pi-hole.net) VM, which is mirrored with GravitySync to a secondary VM and a tertiary hardware Pi. The other ExternalDNS instance syncs DNS records to Cloudflare only when the ingresses and services have an ingress class name of `external` and contain an ingress annotation `external-dns.alpha.kubernetes.io/target`. Most local clients on my network use my PiHoles as the upstream DNS server; some fall back on the Unifi router.

Once I do more testing of Unifi's adblock solution, I may remove the piholes.

---

## 🔧 Hardware

| Device                      | Count | OS Disk Size | Data Disk Size               | Ram  | Operating System | Purpose                 |
|-----------------------------|-------|--------------|------------------------------|------|------------------|-------------------------|
| Gmktec M5 Pro               | 3     | 512GB SSD    | 1TB NVMe                     | 64GB | Proxmox          | VM Hosts                |
| RasPi 4                     | 4     | 512GB SSD    | -                            | 8GB  | Talos            | Kubernetes Workers      |
| RasPi 3                     | 1     | 32GB  SD     | -                            | 8GB  | DietPi           | PiHole                  |
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
