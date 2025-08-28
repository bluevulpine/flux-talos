Conventions:
- Use Kustomize layering with per-app ks.yaml in flux-system namespace; targetNamespace set to the app namespace; path points to app folder.
- HelmReleases prefer chartRef/OCIRepository where available; values kept minimal; enable ServiceMonitor when possible.
- Flux postBuild substitutes variables APP and NS; cluster/domain specifics via ${SECRET_*} vars.
- Certificates: name/secretName derived from ${SECRET_DOMAIN/./-}-<stage>-tls; DNS names list covers primary + subdomains across several domain families.
- Networking migration: prefer Gateway API (Gateways in kube-system) over Ingress; HTTPRoutes per service; Cloudflared entries moved per-host to Gateway service.
- Treat deprecated stacks (rook-ceph) as removable; update dependsOn to longhorn resources.
