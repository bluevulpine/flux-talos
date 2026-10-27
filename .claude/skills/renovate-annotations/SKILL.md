---
name: renovate-annotations
description: "When and where to add a `# renovate: datasource=...` annotation in this repo, and the three cases where adding one is wrong (app-template nested images, a HelmRelease's top-level image, chartRef/OCIRepository versions) because the `flux` manager already tracks them and a second match opens duplicate PRs. Use before adding or removing a Renovate annotation, or when Renovate opens two PRs for one bump."
---

# Renovate version annotations

Annotate a version with `# renovate: datasource=...` when
Renovate cannot detect it natively — a bare version string in `talos/topf.yaml`, a URL
containing a version, a tool pinned in a script. See `talos/topf.yaml` for the pattern.
The annotation goes on the line *directly above* the value (`#1715` fixed one that was
misplaced).

Three cases where the rule is **not** "always annotate":

- **app-template nested container images** (`controllers.*.containers.*.image`) are detected
  natively with no annotation. `kubernetes/apps/productivity/n8n` has none and Renovate has
  opened nine bump PRs for it (#1695, #1617, #1594, …). Annotating anyway is fine and ~47 of
  111 HelmReleases do — the repo is deliberately mixed here. Prefer no annotation for a plain
  semver tag; add one when you want an explicit datasource/depName, as `hermes` (#1743) and
  `timescaledb` (#1715) do.
- **A HelmRelease's top-level `image.repository`/`image.tag`** is already extracted by the
  built-in **`flux`** manager, which parses `values:` inside Flux HelmRelease CRs. Adding an
  annotation there makes **two managers match one line and Renovate open two PRs for one
  bump** — this happened to `gitea` three times (#1389, #1540, #1681). Do not annotate these.

  **`helm-values` is not the manager involved**, despite the name looking right: per
  Renovate's docs it only matches files literally named `values.yaml`/`values.yml`, so it can
  never match a `helmrelease.yaml`. Two successive fixes suppressed the wrong manager and the
  duplicate kept slipping through. `.renovate/overrides.json5` is the authority here and
  explains it at length — read it rather than re-deriving.
- **`chartRef` / OCIRepository versions** are also `flux`-managed. No annotation.

If you add an annotation, check the Renovate Dependency Dashboard (issue #1) afterward for a
duplicate entry.
