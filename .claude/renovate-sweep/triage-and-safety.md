# Renovate sweep — triage & safety

How to classify each open Renovate PR into **safe** / **trivial-fix-then-merge** /
**skip**. Read the diff first (`gh pr diff <#>`), then apply these rules.

## Renovate semantics in this repo

- Renovate runs as `app/renovate[bot]`; PRs carry `renovate` / type labels.
- Update **type** is in the title: patch / minor / major. A `!` in the title
  (`feat(container)!:`) marks a **major / breaking** bump.
- Managers: the **built-in helm-values** manager and a **customManager** (regex on
  `# renovate:` annotations). A single update can legitimately appear in TWO files
  (e.g. a bootstrap helmfile + a Flux OCIRepository) and Renovate may open SEPARATE
  PRs for them — do not assume two PRs touching the same tool are duplicates. Compare
  the **file lists** (`gh pr view <#> --json files`), not just the version, before
  closing anything as a dup.
- Dedup is handled by packageRules in `.renovate/` (e.g. gitea helm-values duplicate
  is disabled there). If you see a genuine dup pattern, fix it with a packageRule
  rather than just closing the PR.

## Risk buckets (lowest → highest)

| Bucket | Examples | Default stance |
| --- | --- | --- |
| **digest / patch — leaf app** | echo-server, frigate, most apps | merge |
| **patch — secrets/storage** | openbao 2.5.x, cnpg patch | merge after health check |
| **minor — leaf app** | most apps | merge (skim changelog) |
| **minor — operator** | flux-operator, cnpg, descheduler, tailscale-operator | merge after changelog + health, one at a time |
| **minor — storage** | Longhorn 1.x | **SKIP** — see below |
| **major (`!`)** | node-red 4→5, http-echo 40→41, checkout v6→v7 | read changelog; skip unless clearly benign |
| **node / cluster** | talos, kubernetes | **SKIP** — not Flux-managed |
| **CRD apiVersion** | `v1beta2 → v1` | merge only if the CRD already serves the new version |

## Breaking-change heuristics

For any minor/major bump, read the upstream release notes (`gh release view <tag>
--repo <owner>/<repo>`). Look specifically for:

- **Removals / "BREAKING" / migration steps** that apply to *this* cluster's config.
  (e.g. Longhorn 1.12 removes V2 backing images — irrelevant here because all volumes
  are V1 data engine. Read carefully before assuming a "breaking" note applies.)
- **No-downgrade** statements (Longhorn). One-way upgrades never go in an automated
  sweep — flag for a maintenance window.
- **CRD / API changes**, default-value changes, renamed settings.
- For a `!` bump that is really just a base-image / runtime version (e.g.
  actions/checkout v7 = Node 24 runtime, transparent on GitHub-hosted runners), it's
  usually safe — confirm via the PR's own green CI.

## Bootstrap-vs-Flux: does merging actually deploy anything?

Critical distinction — some "apps" are installed at **bootstrap** by Helmfile, NOT by
Flux. Merging a bump to those changes a pinned version that only takes effect on the
next bootstrap run; **nothing rolls out and there is nothing to monitor.**

- Bootstrap-managed: anything under `bootstrap/helmfile.d/` (e.g. `00-crds.yaml`,
  `01-apps.yaml`). This includes external-secrets, external-dns, envoy-gateway,
  **keda**, kube-prometheus-stack, flux-operator's helmfile entry, etc.
- Flux-managed: anything under `kubernetes/apps/**` via HelmRelease/OCIRepository/
  Kustomization.

Check which file the PR touches (`gh pr view <#> --json files`). If it's only a
bootstrap helmfile, note "bootstrap-only, inert until next bootstrap" and move on.

> **Watch-out:** a bump can be *both* inert AND for something not even running. keda
> is declared in `bootstrap/helmfile.d/00-crds.yaml` (ns observability) but has **no
> running pods / no ScaledObjects** — the only reference is the unused
> `kubernetes/components/nfs-scaler/` component. Merging keda bumps is doubly inert.
> Flag dead config like this rather than silently merging forever.

## CRD apiVersion migrations (e.g. image.toolkit.fluxcd.io v1beta2 → v1)

Safe to merge **only if the installed CRD already serves the target version**:

```
kubectl get crd <plural>.<group> -o jsonpath='{.spec.versions[*].name}'
```

If the new version is listed, the manifest apiVersion bump is a no-op re-apply of a
control object (not a workload) — merge. If not served, skip (the controller/CRD
needs upgrading first).

## Always skip in an automated sweep (flag for maintenance window)

- **talos** / **kubernetes** version bumps — node OS / control-plane upgrades driven
  by talhelper + a controlled rollout, not Flux.
- **Longhorn** (and any no-downgrade storage) minors.
- **Major (`!`)** bumps that need app-side migration (node-red 4→5, homebox-companion
  3.x, etc.).
- Anything that requires a **new secret in OpenBao** before it can run (e.g. a homebox
  build that mandates `HBOX_AUTH_API_KEY_PEPPER`). Provision the secret first, separately.
