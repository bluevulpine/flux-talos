## OCI Migration Summary

This document summarizes the migration from HelmRepository to OCIRepository across the flux-talos cluster.

### Scope and approach
- Pattern based on local mosquitto example (OCIRepository in app namespace + HelmRelease.spec.chartRef)
- Referenced onedr0p/home-ops for examples and tag/URL conventions
- Converted all workloads that have confirmed OCI Helm charts; left others on traditional HelmRepository when no official OCI is available

---

### Successfully converted workloads (HelmRepository -> OCIRepository)
Note: After-migration uses HelmRelease.spec.chartRef to an OCIRepository in the same namespace.

Converted earlier in this effort (selection):
- app-template-based apps (20+): moved to oci://ghcr.io/bjw-s-labs/helm/app-template:3.7.3
- external-secrets: oci://ghcr.io/external-secrets/charts/external-secrets:0.20.4
- cilium: oci://ghcr.io/home-operations/charts-mirror/cilium:1.18.3
- metrics-server: oci://ghcr.io/home-operations/charts-mirror/metrics-server:3.13.0
- descheduler: oci://ghcr.io/home-operations/charts-mirror/descheduler:0.34.0
- csi-driver-nfs: oci://ghcr.io/home-operations/charts-mirror/csi-driver-nfs:4.12.1
- openebs: oci://ghcr.io/home-operations/charts-mirror/openebs:3.10.0
- kube-prometheus-stack: oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack:79.0.1
- prometheus-smartctl-exporter: oci://ghcr.io/prometheus-community/charts/prometheus-smartctl-exporter:0.16.0
- reloader: oci://ghcr.io/stakater/charts/reloader:2.2.3
- external-dns (cloudflare/unifi): oci://ghcr.io/home-operations/charts-mirror/external-dns:1.19.0
- volsync: oci://ghcr.io/home-operations/charts-mirror/volsync-perfectra1n:0.17.15

Converted in this pass:
- grafana
  - Before: HelmRepository grafana (https://grafana.github.io/helm-charts)
  - After: OCIRepository url=oci://ghcr.io/grafana/helm-charts/grafana, tag=10.1.4
  - Files: kubernetes/apps/observability/grafana/app/{ocirepository.yaml, helmrelease.yaml}
- loki
  - Before: HelmRepository grafana (https://grafana.github.io/helm-charts)
  - After: OCIRepository url=oci://ghcr.io/grafana/helm-charts/loki, tag=6.45.2
  - Files: kubernetes/apps/observability/loki/app/{ocirepository.yaml, helmrelease.yaml}
- thanos
  - Before: HelmRepository stevehipwell (https://stevehipwell.github.io/helm-charts)
  - After: OCIRepository url=oci://ghcr.io/stevehipwell/helm-charts/thanos, tag=1.21.1
  - Files: kubernetes/apps/observability/thanos/app/{ocirepository.yaml, helmrelease.yaml}
- actions-runner-controller (runner scale set)
  - Before: HelmRepository actions-runner-controller (oci://ghcr.io/actions/actions-runner-controller-charts)
  - After: OCIRepository url=oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set, tag=0.13.0
  - Files: kubernetes/apps/actions-runner-system/actions-runner-controller/runners/{ocirepository.yaml, helmrelease.yaml}

Repository cleanups in flux-system:
- Removed from kubernetes/apps/flux-system/repositories/helm/kustomization.yaml:
  - ./actions-runner-controller.yaml
  - ./grafana.yaml
  - ./stevehipwell.yaml
- Deleted files:
  - kubernetes/apps/flux-system/repositories/helm/actions-runner-controller.yaml
  - kubernetes/apps/flux-system/repositories/helm/grafana.yaml
  - kubernetes/apps/flux-system/repositories/helm/stevehipwell.yaml

---

### Workloads requiring further research or left on HelmRepository
- seaweedfs
  - Finding: Bitnami publishes an OCI chart, but values schema differs from current SeaweedFS chart. Migration would require non-trivial value mapping/testing. Left as HelmRepository for now.

### Workloads that cannot be converted to OCI (no official OCI chart available)
- cloudnative-pg: https://cloudnative-pg.github.io/charts (no official OCI chart)
- longhorn: https://charts.longhorn.io (no official OCI chart)
- k8s-gateway: https://ori-edge.github.io/k8s_gateway (no official OCI chart)
- tailscale-operator: Helm repo only; OCI support requested upstream, not available yet
- node-feature-discovery: https://kubernetes-sigs.github.io/node-feature-discovery/charts (no official OCI chart)
- kubelet-csr-approver: https://postfinance.github.io/kubelet-csr-approver (no official OCI chart)
- nvidia-device-plugin: https://nvidia.github.io/k8s-device-plugin (no official OCI chart)

---

### Notes
- HelmRelease now uses `spec.chartRef` (kind: OCIRepository) for OCI-based charts; this is the pattern used in onedr0p/home-ops.
- OCIRepository resources are created per-app in the same namespace and added to the app kustomization.
- Where multiple apps used a single HelmRepository, we only removed the flux-system repository after all consumers were converted.

