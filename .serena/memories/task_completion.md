When completing changes:
1. Validate manifests: task kubernetes:kubeconform
2. Flux apply path added to kustomizations (ensure included under kube-system or appropriate aggregate kustomization)
3. Reconcile Flux: flux reconcile kustomization -n flux-system <name>
4. Verify: kubectl get/describe resources (certificates, secrets, gateways, httproutes, ingress, services)
5. For networking changes: check Cloudflared logs and connectivity (curl, gatus where applicable)
6. Rollback plan: re-point Cloudflared to ingress-nginx or revert kustomization entries if issues
