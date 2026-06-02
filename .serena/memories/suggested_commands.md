# Suggested Commands — flux-talos

All commands assume `.envrc` is sourced (direnv) or `.mise.toml` env is active.

## Just task runner (top-level)

```bash
just -l                          # list all recipes
just kube apply-ks <dir> [ks]    # apply local Flux Kustomization via kubectl server-side
just kube delete-ks <dir> [ks]   # delete a Kustomization
just kube sync-hr                # force-reconcile all HelmReleases
just kube sync-es                # force-sync all ExternalSecrets
just kube sync-git               # force-reconcile all GitRepositories
just kube snapshot               # trigger VolSync manual snapshot on all PVCs
just kube prune-pods             # delete Failed/Pending/Succeeded pods
just kube node-shell <node>      # debug shell on a node via kubectl debug
just kube browse-pvc <ns> <pvc>  # browse PVC contents

just talos gen-config            # regenerate talhelper machine configs
just talos upgrade-node <node>   # upgrade Talos on a node (powercycle)
just talos upgrade-k8s <version> # upgrade Kubernetes version
just talos reboot-node <node>    # reboot a node
just talos download-image <ver> <schematic>
```

## kubectl / flux shortcuts

```bash
kubectl get hr -A                # list all HelmReleases
kubectl get ks -A                # list all Flux Kustomizations
flux reconcile kustomization cluster-apps --with-source
flux reconcile helmrelease <name> -n <ns>
```

## Secret management

```bash
sops -d <file.sops.yaml>         # decrypt in-place view
sops <file.sops.yaml>            # edit encrypted file
```

## Linting / formatting

```bash
yamlfmt <file>                   # format YAML (exclude *.sops.yaml)
lefthook run pre-commit          # run all pre-commit hooks manually
flux-local test                  # validate Flux manifests locally (CI equiv)
```
