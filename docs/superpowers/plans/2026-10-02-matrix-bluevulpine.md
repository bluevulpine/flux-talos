# bluevulpine.net Matrix Homeserver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a second Matrix homeserver whose identity is `bluevulpine.net` (`@bluevulpine:bluevulpine.net`), Authentik-gated, federating, with one Element Web serving both `chat.derekjacobs.dev` and `chat.bluevulpine.net`.

**Architecture:** A second release of the ESS `matrix-stack` chart in a new namespace `matrix-bluevulpine`, mirroring `kubernetes/apps/matrix/matrix-stack` (db Kustomization → app Kustomization). It deviates from that tree in four places: role and database names `synapse_bluevulpine`/`mas_bluevulpine`, OpenBao key `matrix-bluevulpine`, a plain 2-replica media PVC backed up by kopiur, and no Element Web/Admin. The existing release's Element Web gains a second hostname, plus a per-host `config.<host>.json` mounted through a `postRenderer` patch. Shipped as two PRs: PR A builds the new homeserver and changes nothing live; PR B touches the live derekjacobs.dev release.

**Tech Stack:**
- Flux (Kustomization, HelmRelease, OCIRepository)
- ESS `matrix-stack` chart (`oci://ghcr.io/element-hq/ess-helm/matrix-stack`)
- Gateway API (Envoy Gateway)
- external-dns
- External Secrets + OpenBao
- CloudNativePG `postgres18` with `postgres-init`
- kopiur
- Longhorn
- Authentik
- Pangolin (VPS Traefik)

**Spec:** `docs/superpowers/specs/2026-10-02-matrix-bluevulpine-design.md`. Read it first; this plan implements it and does not restate the reasoning.

## Global Constraints

- Repo root for every command: `/Users/bluevulpine/Repositories/flux-talos/.claude/worktrees/matrix-bluevulpine` (git worktree, branch `worktree-matrix-bluevulpine`). Never `cd` to the main checkout.
- **Git in this worktree is currently blocked:** the RTK hook rewrites `git` → `rtk git`, and the worktree guard refuses it. Commit steps cannot run until Derek resolves that (e.g. excluding `git` from the RTK hook). Do not work around the guard.
- **Never commit unless Derek asks.** When he does: Scoped Commits (`<scope>: <description>`, no `feat:`/`fix:`). Author `fizz-bot-bvn[bot] <324971095+fizz-bot-bvn[bot]@users.noreply.github.com>`, set only via per-command `git -c user.name=… -c user.email=… commit`, never `git config`. Trailers: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa`.
- Never `lefthook run pre-commit --all-files`; only `lefthook run pre-commit` on staged files.
- Every `.yaml` must pass `yamlfmt` (block-style arrays, `---` document start, LF).
- Every Kubernetes manifest starts with `# yaml-language-server: $schema=<url>`. Use only these URLs (each checked to return JSON on 2026-10-02):
  - Namespace / PVC / ConfigMap: `https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.36.2-standalone-strict/{namespace,persistentvolumeclaim,configmap}-v1.json`
  - Flux Kustomization: `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json`
  - kustomize `kustomization.yaml`: `https://json.schemastore.org/kustomization`
  - HelmRelease: `https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json`
  - OCIRepository: `https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json`
  - ExternalSecret: `https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json`
  - HTTPRoute: `https://kubernetes-schemas.pages.dev/gateway.networking.k8s.io/httproute_v1.json`
  - HTTPRouteFilter: `https://kubernetes-schemas.pages.dev/gateway.envoyproxy.io/httproutefilter_v1alpha1.json`
  - DNSEndpoint: `https://kubernetes-schemas.pages.dev/externaldns.k8s.io/dnsendpoint_v1alpha1.json`
  - Job: `https://k8s-schemas.home-operations.com/batch/job_v1.json`
- Do not add `crds:` or `install/upgrade.strategy` to the HelmRelease: `cluster-apps` injects both.
- Runtime `$VAR`s inside manifests that Flux substitutes must be written `$${VAR}`.
- No agent writes to OpenBao or Authentik (the sandbox blocks the first, and Authentik is done by hand by spec). The agent reads, verifies, and hands over exact steps.
- Fixed values, used verbatim:
  - Namespace `matrix-bluevulpine`; OpenBao key `matrix-bluevulpine`; Postgres roles/DBs `synapse_bluevulpine`, `mas_bluevulpine`.
  - MAS upstream provider ULID `01M3YQ563JRK4NR03FA7JVPD2H`. Never regenerate it: it is part of the Authentik redirect URI.
  - Authentik app slug `matrix-bluevulpine`; group `matrix-bluevulpine-users`; issuer `https://sso.${SECRET_DOMAIN}/application/o/matrix-bluevulpine/`.
  - Media PVC `synapse-media`, 20Gi, RWO, `longhorn-2-replica`. kopiur staging and cache stay on `longhorn-1-replica`.
  - kopiur crons: local `H */2 * * *`, R2 `H 6 * * *`.

## Review Focus

1. **Secrets borrowed from derekjacobs.dev.** If either ExternalSecret still extracts key `matrix`, the new Synapse starts with derekjacobs.dev's signing key and no error. Task 3 and Task 4 tests assert the rendered key.
2. **Backups that never run.** A missing `privileged-movers` annotation, or wrong `KOPIUR_*` defaults (copy method `Direct`, NFS snapshot class, uid 0), leaves Snapshots `Pending` with no alert. Task 3 and Task 4 assert the annotation and every var; Task 9 gates on `Succeeded`.
3. **The apex `.well-known` stealing or losing traffic.** It must claim only `/.well-known/matrix`, on both `external` and `internal`, without touching the blog route. Task 5 asserts the match and parents; Task 9 checks LAN and public responses, and that the blog still returns 200.
4. **Name collisions on shared Postgres.** The literals `synapse`/`mas` must not survive anywhere in the new tree. Task 3 and Task 4 grep the rendered output.
5. **The per-host Element Web config silently not loading.** That happens on a wrong filename (it must be the exact hostname), a missing mount, or no restart after edits. Task 11 asserts the rendered mount path and the Reloader annotation, and checks live that both hostnames serve their own default homeserver.

---

## File Structure

**PR A** (new homeserver; nothing live changes until merge):

| File | Responsibility |
| --- | --- |
| `scripts/matrix-generate-secrets.sh` (modify) | Optional OpenBao path argument |
| `scripts/tests/matrix-generate-secrets-args.sh` (create) | Argument-parsing test with a fake `bao` |
| `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-local.yaml` (modify) | Allow the namespace |
| `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-r2.yaml` (modify) | Allow the namespace |
| `kubernetes/apps/kopiur-system/repositories/app/externalsecrets.yaml` (modify) | Repository credentials in the namespace |
| `kubernetes/apps/matrix-bluevulpine/namespace.yaml` (create) | Namespace + PSA labels + privileged-movers annotations |
| `kubernetes/apps/matrix-bluevulpine/kustomization.yaml` (create) | Namespace entrypoint |
| `kubernetes/apps/matrix-bluevulpine/matrix-stack/ks.yaml` (create) | Two Flux Kustomizations: db → app |
| `kubernetes/apps/matrix-bluevulpine/matrix-stack/db/{kustomization,externalsecret,job}.yaml` (create) | Roles/DBs + collation assert |
| `kubernetes/apps/matrix-bluevulpine/matrix-stack/app/{kustomization,ocirepository,externalsecret,helmrelease,pvc}.yaml` (create) | Homeserver, secrets, media volume, kopiur |
| `kubernetes/apps/matrix-bluevulpine/matrix-stack/app/{httproute,dnsendpoint}.yaml` (create) | Routes, apex well-known, public CNAMEs |
| `kubernetes/apps/matrix-bluevulpine/matrix-stack/README.md` (create) | Layout, manual steps, verify, recovery |

**PR B** (live derekjacobs.dev release):

| File | Responsibility |
| --- | --- |
| `kubernetes/apps/matrix/matrix-stack/app/element-web-bluevulpine.yaml` (create) | ConfigMap with `config.chat.<blog>.json` |
| `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml` (modify) | 4th `postRenderer` patch: mount + Reloader |
| `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml` (modify) | Second `chat` hostname |
| `kubernetes/apps/matrix/matrix-stack/app/dnsendpoint.yaml` (modify) | `chat.<blog>` CNAME |
| `kubernetes/apps/matrix/matrix-stack/app/kustomization.yaml` (modify) | Include the ConfigMap |
| `kubernetes/apps/matrix/matrix-stack/README.md` (modify) | Mention the shared client |

**Shared test helper** (used by Tasks 3–5 and 11; nothing is created on disk). Renders a directory the way Flux would, with the cluster-settings values the tests care about:

```bash
render() { # dir, then KEY=VAL pairs for the Kustomization's postBuild.substitute
  local dir="$1"; shift
  kustomize build "$dir" | env \
    SECRET_DOMAIN=derekjacobs.dev SECRET_DOMAIN_BLOG=bluevulpine.net \
    POSTGRES_HOST=postgres18-rw.database.svc.cluster.local "$@" \
    flux envsubst --strict
}
```

`flux envsubst --strict` fails on any unset `${VAR}` without a default. That's the point: it catches a typo'd substitution before Flux does.

---

### Task 0: Unblock git in the worktree

**Files:** none (environment).

- [ ] **Step 1: Confirm the block**

Run: `git status --short`
Expected: refusal mentioning "runs rtk with a git command among its operands".

- [ ] **Step 2: Hand to Derek**

Ask Derek how he wants to resolve it (e.g. exclude `git` from the RTK rewrite hook, or approve another mechanism). **Do not edit hooks or settings yourself.**

- [ ] **Step 3: Verify**

Run: `git status --short && git log --oneline -1`
Expected: a short status listing `docs/superpowers/` files, and the base commit.

- [ ] **Step 4: Chart bump first (spec rollout step 0)**

Derek merges #2002 (chart 26.9.3 → 26.9.4; CI green). Then: `git fetch origin && git rebase origin/main`. Confirm with `yq '.spec.ref.tag' kubernetes/apps/matrix/matrix-stack/app/ocirepository.yaml`.
Expected: `26.9.4`, so Task 4's copied `ocirepository.yaml` starts on the current chart.

---

### Task 1: Secret script takes an OpenBao path

**Files:**
- Modify: `scripts/matrix-generate-secrets.sh` (header usage comment, lines 1–29)
- Create: `scripts/tests/matrix-generate-secrets-args.sh`

**Interfaces:**
- Produces: `scripts/matrix-generate-secrets.sh [--dry-run] [path]` in either order; `path` defaults to `secret/matrix`. Used by Task 8.

- [ ] **Step 1: Write the failing test**

`scripts/tests/matrix-generate-secrets-args.sh`:

```bash
#!/bin/bash
# Argument parsing for matrix-generate-secrets.sh, against a FAKE bao on PATH.
# The fake records the path of every `kv get` and makes every field "missing",
# so the script reaches its final dry-run exit without touching OpenBao.
#
# /bin/bash on purpose: a zsh -c would re-read ~/.zshenv and put the REAL bao
# first on PATH (reference_zsh_c_resets_fake_path).
set -euo pipefail

readonly SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/matrix-generate-secrets.sh"
fake="$(mktemp -d)"
trap 'rm -rf "${fake}"' EXIT

cat >"${fake}/bao" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "token lookup") exit 0 ;;
  "kv get")
    for a in "$@"; do [[ "$a" == secret/* ]] && echo "$a" >>"${BAO_FAKE_LOG}"; done
    echo "No value found at ${!#}" >&2; exit 2 ;;
  "kv put"|"kv patch") echo "FAKE BAO REFUSES WRITES" >&2; exit 99 ;;
esac
exit 0
EOF
chmod +x "${fake}/bao"

run() { # expected-path, args...
  local want="$1"; shift
  export BAO_FAKE_LOG="${fake}/log"; : >"${BAO_FAKE_LOG}"
  PATH="${fake}:${PATH}" "${SCRIPT}" "$@" >/dev/null
  local got; got="$(sort -u "${BAO_FAKE_LOG}")"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: args [$*] read path [${got}], want [${want}]" >&2; exit 1
  fi
  echo "ok:   args [$*] -> ${want}"
}

run secret/matrix             --dry-run
run secret/matrix-bluevulpine --dry-run secret/matrix-bluevulpine
run secret/matrix-bluevulpine secret/matrix-bluevulpine --dry-run

# Unknown flags must abort, not be taken as a path.
if PATH="${fake}:${PATH}" "${SCRIPT}" --dryrun >/dev/null 2>&1; then
  echo "FAIL: unknown flag --dryrun was accepted" >&2; exit 1
fi
echo "ok:   unknown flag rejected"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x scripts/tests/matrix-generate-secrets-args.sh && /bin/bash scripts/tests/matrix-generate-secrets-args.sh`
Expected: `ok: args [--dry-run] -> secret/matrix`, then `FAIL: args [--dry-run secret/matrix-bluevulpine] read path [secret/matrix] …`.

- [ ] **Step 3: Implement**

In `scripts/matrix-generate-secrets.sh`, replace

```bash
readonly BAO_PATH="secret/matrix"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
```

with

```bash
# [--dry-run] [path], in either order. path defaults to secret/matrix, so the
# original single-homeserver usage is unchanged. Each homeserver has its own key
# (secret/matrix, secret/matrix-bluevulpine): never point two at one key, or they
# share a signing key.
DRY_RUN=false
BAO_PATH="secret/matrix"
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        -*) echo "ERROR: unknown option ${arg}" >&2; exit 1 ;;
        *) BAO_PATH="${arg}" ;;
    esac
done
readonly BAO_PATH DRY_RUN
```

and in the header, replace the `# Populates OpenBao secret/matrix …` line and the `Usage` block with

```bash
# Populates an OpenBao KV path (default secret/matrix) with every secret the ESS
# matrix-stack chart needs. One path per homeserver: secret/matrix for
# kubernetes/apps/matrix/matrix-stack, secret/matrix-bluevulpine for
# kubernetes/apps/matrix-bluevulpine/matrix-stack.
```

```bash
# Usage:
#   ./scripts/matrix-generate-secrets.sh [--dry-run] [path]
#   ./scripts/matrix-generate-secrets.sh --dry-run secret/matrix-bluevulpine
```

- [ ] **Step 4: Run the test and shellcheck**

Run: `/bin/bash scripts/tests/matrix-generate-secrets-args.sh && shellcheck scripts/matrix-generate-secrets.sh scripts/tests/matrix-generate-secrets-args.sh`
Expected: four `ok:` lines; shellcheck silent.

- [ ] **Step 5: Commit (only if Derek has asked)**

```bash
git add scripts/matrix-generate-secrets.sh scripts/tests/matrix-generate-secrets-args.sh
git -c user.name='fizz-bot-bvn[bot]' -c user.email='324971095+fizz-bot-bvn[bot]@users.noreply.github.com' \
  commit -m 'scripts/matrix: take the OpenBao path as an argument' \
  -m 'Lets one script provision secret/matrix-bluevulpine for the second homeserver. Default unchanged.' \
  -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' \
  -m 'Claude-Session: https://claude.ai/code/session_01AA9xxfsX3xSg8xher3SAKa'
```

---

### Task 2: Let kopiur back up the new namespace

**Files:**
- Modify: `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-local.yaml` (`allowedNamespaces.list`, ~line 47)
- Modify: `kubernetes/apps/kopiur-system/repositories/app/clusterrepository-r2.yaml` (`allowedNamespaces.list`, ~line 31)
- Modify: `kubernetes/apps/kopiur-system/repositories/app/externalsecrets.yaml` (header line 3 + append two documents)

**Interfaces:**
- Produces: Secrets `kopiur-local-secret` and `kopiur-r2-secret` in `matrix-bluevulpine`, and the namespace allowed on `ClusterRepository` `kopia-local` and `kopia-r2`. Consumed by Task 4's SnapshotPolicies.

- [ ] **Step 1: Write the failing check**

```bash
out="$(kustomize build kubernetes/apps/kopiur-system/repositories/app)"
echo "$out" | yq -e 'select(.kind=="ClusterRepository") | .spec.allowedNamespaces.list | contains(["matrix-bluevulpine"])' | grep -c true   # want 2
echo "$out" | yq -e 'select(.kind=="ExternalSecret" and .metadata.namespace=="matrix-bluevulpine") | .spec.target.name'                   # want both secret names
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `0`, then a `yq` error (no matches).

- [ ] **Step 3: Implement**

In **both** ClusterRepository files, insert `- matrix-bluevulpine` alphabetically between `- identity` and `- media`:

```yaml
      - identity
      - matrix-bluevulpine
      - media
```

In `externalsecrets.yaml`, change header line 3 from `9 namespaces x 2 legs` to `10 namespaces x 2 legs`, and append:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kopiur-local
  namespace: matrix-bluevulpine
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  refreshInterval: 5m
  target:
    name: kopiur-local-secret
    template:
      engineVersion: v2
      data:
        KOPIA_PASSWORD: "{{ .VolSync__Local__KopiaPassword }}"
        AWS_ACCESS_KEY_ID: "{{ .VolSync__Local__AwsAccessKeyId }}"
        AWS_SECRET_ACCESS_KEY: "{{ .VolSync__Local__AwsSecretKey }}"
  dataFrom:
    - extract:
        key: volsync-local-template
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kopiur-r2
  namespace: matrix-bluevulpine
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  refreshInterval: 5m
  target:
    name: kopiur-r2-secret
    template:
      engineVersion: v2
      data:
        KOPIA_PASSWORD: "{{ .VolSync__R2__KopiaPassword }}"
        AWS_ACCESS_KEY_ID: "{{ .VolSync__R2__AwsAccessKeyId }}"
        AWS_SECRET_ACCESS_KEY: "{{ .VolSync__R2__AwsSecretKey }}"
  dataFrom:
    - extract:
        key: volsync-r2-template
```

Before pasting, diff these two blocks against the existing `download` pair. They must be byte-identical apart from `namespace`. If the file has drifted since this plan was written, copy the current `download` pair instead.

- [ ] **Step 4: Re-run the check and format**

Run the Step 1 commands, then `yamlfmt kubernetes/apps/kopiur-system/repositories/app/*.yaml && git diff --stat`.
Expected: `2`, then `kopiur-local-secret` and `kopiur-r2-secret`. The diff touches only the three files.

- [ ] **Step 5: Commit (only if asked)**: `kopiur-system: allow the matrix-bluevulpine namespace`, with the same `-c` author and trailers as Task 1.

---

### Task 3: Namespace and database provisioning

**Files:**
- Create: `kubernetes/apps/matrix-bluevulpine/namespace.yaml`
- Create: `kubernetes/apps/matrix-bluevulpine/kustomization.yaml`
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/ks.yaml` (both Kustomizations; Task 4 relies on the `app` one)
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/db/kustomization.yaml`, `db/externalsecret.yaml`, `db/job.yaml`

**Interfaces:**
- Consumes: Task 2's namespace allow-list (via `dependsOn: kopiur-repositories` in the app Kustomization).
- Produces: Flux Kustomizations `matrix-stack-db` and `matrix-stack` in namespace `matrix-bluevulpine`. Postgres roles/DBs `synapse_bluevulpine` and `mas_bluevulpine`. Secret `matrix-db-init-secret` with keys `SYNAPSE_POSTGRES_PASS` and `MAS_POSTGRES_PASS`.

- [ ] **Step 1: Write the failing check**

```bash
db="$(render kubernetes/apps/matrix-bluevulpine/matrix-stack/db APP=matrix-stack-db)"
echo "$db" | yq -e 'select(.kind=="ExternalSecret") | .spec.dataFrom[].extract.key' | sort   # want: cloudnative-pg, matrix-bluevulpine
echo "$db" | yq -e 'select(.kind=="Job") | .spec.template.spec.initContainers[].env[] | select(.name=="INIT_POSTGRES_USER" or .name=="INIT_POSTGRES_DBNAME") | .value' | sort -u   # want: mas_bluevulpine, synapse_bluevulpine
echo "$db" | grep -n -E "datname = 'synapse_bluevulpine'"                                       # want 1 line
echo "$db" | grep -n -E "value: (synapse|mas)$|key: matrix$|datname = 'synapse'" && echo "LEAK" || echo "clean"
ns="$(kustomize build kubernetes/apps/matrix-bluevulpine)"
echo "$ns" | yq -e 'select(.kind=="Namespace") | .metadata.annotations["kopiur.home-operations.com/privileged-movers"]'   # want "true"
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `kustomize build` errors, because the directory doesn't exist.

- [ ] **Step 3: Implement**

`kubernetes/apps/matrix-bluevulpine/namespace.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.36.2-standalone-strict/namespace-v1.json
# Second Matrix homeserver (bluevulpine.net). Separate from `matrix` so each
# identity keeps its own secrets, policies and blast radius.
apiVersion: v1
kind: Namespace
metadata:
  name: matrix-bluevulpine
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/audit: privileged
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
    volsync.backube/privileged-movers: "true"
    # kopiur refuses movers with added capabilities (components/kopiur always adds
    # DAC_OVERRIDE) unless the namespace opts in, and NOTHING alerts: Snapshots sit
    # Pending (PrivilegedMoverNotPermitted) forever. docs/runbooks/kopiur-migration.md
    kopiur.home-operations.com/privileged-movers: "true"
```

`kubernetes/apps/matrix-bluevulpine/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: matrix-bluevulpine
components:
  - ../../components/common
resources:
  - ./namespace.yaml
  - ./matrix-stack/ks.yaml
```

`kubernetes/apps/matrix-bluevulpine/matrix-stack/ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
# Second homeserver, bluevulpine.net. Same two-step shape as
# kubernetes/apps/matrix/matrix-stack: the databases exist (and pass the C
# collation assertion) before Synapse/MAS start. Design:
# docs/superpowers/specs/2026-10-02-matrix-bluevulpine-design.md
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app matrix-stack-db
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: matrix-stack
  dependsOn:
    # NOTE the `18` suffix — there is no `cloudnative-pg-cluster` Kustomization, and
    # Flux parks silently on a missing dependsOn target.
    - name: cloudnative-pg-cluster18
      namespace: database
    - name: external-secrets-openbao-store
      namespace: external-secrets
  path: ./kubernetes/apps/matrix-bluevulpine/matrix-stack/db
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: matrix-bluevulpine
  # wait: the Job is health-checked, so this is Ready only once the databases exist.
  wait: true
  # The Job deletes itself and every reconcile recreates it, re-syncing role passwords.
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  postBuild:
    substitute:
      APP: *app
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app matrix-stack
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: matrix-stack-db
    - name: external-secrets-openbao-store
      namespace: external-secrets
    # components/kopiur's SnapshotPolicies are rejected by the fail-closed webhook
    # until the ClusterRepositories (and their allowedNamespaces) exist.
    - name: kopiur-repositories
      namespace: kopiur-system
  path: ./kubernetes/apps/matrix-bluevulpine/matrix-stack/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
    namespace: flux-system
  targetNamespace: matrix-bluevulpine
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 10m
  postBuild:
    substitute:
      # APP names the media PVC and its kopiur policies (components/kopiur), which
      # is why it is not the Kustomization name.
      APP: synapse-media
      # NS is kopiur's snapshot identity hostname (synapse-media@matrix-bluevulpine:/data).
      # It has no default, so it must be set.
      NS: matrix-bluevulpine
      # Synapse holds the RWO volume, so the mover cannot co-mount it: snapshot it.
      KOPIUR_COPYMETHOD: Snapshot
      KOPIUR_SNAPSHOTCLASS: longhorn-snapclass
      # Mover runs as Synapse's own uid/gid (chart default 10091), not root.
      # (VOLSYNC_RUN_AS_* in the derekjacobs.dev instance do nothing for kopiur.)
      KOPIUR_RUN_AS_USER: "10091"
      KOPIUR_RUN_AS_GROUP: "10091"
      KOPIUR_FS_GROUP: "10091"
      # H picks the minute per schedule. R2 hour 6 is one of the two least-used
      # H hours, and the derekjacobs.dev instance's hour.
      KOPIUR_LOCAL_CRON: "H */2 * * *"
      KOPIUR_R2_CRON: "H 6 * * *"
```

`db/kustomization.yaml`, `db/externalsecret.yaml`, `db/job.yaml`: **copy** the three files from `kubernetes/apps/matrix/matrix-stack/db/` and make exactly these changes. Every other line stays identical.

| File | Change |
| --- | --- |
| `db/externalsecret.yaml` | header comment: `step 2` → `the app Kustomization`; `key: matrix` → `key: matrix-bluevulpine` |
| `db/job.yaml` | `01-init-synapse` env: `INIT_POSTGRES_USER`/`INIT_POSTGRES_DBNAME` values `synapse` → `synapse_bluevulpine` |
| `db/job.yaml` | `02-init-mas` env: `mas` → `mas_bluevulpine` (both) |
| `db/job.yaml` | assertion SQL: `WHERE datname = 'synapse'` → `WHERE datname = 'synapse_bluevulpine'` |
| `db/job.yaml` | assertion echo/error text: `synapse database` → `synapse_bluevulpine database` (two places) |
| `db/job.yaml` | recovery comment: `DROP DATABASE synapse;` / `CREATE DATABASE synapse OWNER synapse` → `synapse_bluevulpine` throughout |
| `db/job.yaml` | rerun comment: `kubectl -n matrix delete job` → `kubectl -n matrix-bluevulpine delete job` |

Then confirm nothing was missed:

```bash
grep -n -w -E 'synapse|mas|matrix' kubernetes/apps/matrix-bluevulpine/matrix-stack/db/*.yaml
```

Every remaining hit must be in a comment or part of a compound name (`matrix-db-init`, `cloudnative-pg`), and none may be a role, database or key value.

- [ ] **Step 4: Re-run the check, then format**

Run the Step 1 commands, then `yamlfmt kubernetes/apps/matrix-bluevulpine`.
Expected: `cloudnative-pg` and `matrix-bluevulpine`; `mas_bluevulpine` and `synapse_bluevulpine`; one `datname` line; `clean`; `true`.

- [ ] **Step 5: Commit (only if asked)**: `matrix-bluevulpine: namespace and database provisioning`.

---

### Task 4: The homeserver, media volume and backups

**Files:**
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/app/kustomization.yaml`
- Create: `.../app/ocirepository.yaml`, `.../app/externalsecret.yaml`, `.../app/helmrelease.yaml`, `.../app/pvc.yaml`

**Interfaces:**
- Consumes: Task 3's `matrix-stack` Kustomization substitutions (`APP`, `NS`, `KOPIUR_*`) and DB names.
- Produces: Services `matrix-stack-synapse:8008`, `matrix-stack-matrix-authentication-service:8080` and `matrix-stack-well-known:8010` in `matrix-bluevulpine` (Task 5 routes to them); Secret `matrix-stack-secret`; PVC `synapse-media`; SnapshotPolicies `synapse-media-local` and `synapse-media-r2`.

- [ ] **Step 1: Write the failing check**

```bash
V=(APP=synapse-media NS=matrix-bluevulpine KOPIUR_COPYMETHOD=Snapshot KOPIUR_SNAPSHOTCLASS=longhorn-snapclass \
   KOPIUR_RUN_AS_USER=10091 KOPIUR_RUN_AS_GROUP=10091 KOPIUR_FS_GROUP=10091 \
   KOPIUR_LOCAL_CRON='H */2 * * *' KOPIUR_R2_CRON='H 6 * * *')
app="$(render kubernetes/apps/matrix-bluevulpine/matrix-stack/app "${V[@]}")"
echo "$app" | yq -e 'select(.kind=="ExternalSecret") | .spec.dataFrom[].extract.key'                       # want: matrix-bluevulpine
echo "$app" | yq -e 'select(.kind=="ExternalSecret") | .spec.target.template.data["mas-upstream-authentik.yaml"]' | grep -E 'id: 01M3YQ563JRK4NR03FA7JVPD2H|issuer: "https://sso.derekjacobs.dev/application/o/matrix-bluevulpine/"' | wc -l   # want 2
echo "$app" | yq -e 'select(.kind=="PersistentVolumeClaim") | [.spec.storageClassName, .spec.dataSourceRef == null] | @tsv'   # want: longhorn-2-replica  true
echo "$app" | yq -e 'select(.kind=="SnapshotPolicy") | [.metadata.name, .spec.copyMethod, .spec.volumeSnapshotClassName, .spec.staging.storageClassName, .spec.mover.securityContext.runAsUser, .spec.identity.hostname] | @tsv'
#   want, twice (-local, -r2): Snapshot  longhorn-snapclass  longhorn-1-replica  10091  matrix-bluevulpine
echo "$app" | yq -e 'select(.kind=="HelmRelease") | .spec.values | [.serverName, .synapse.postgres.user, .synapse.postgres.database, .matrixAuthenticationService.postgres.user, .matrixAuthenticationService.postgres.database, .elementWeb.enabled, .elementAdmin.enabled, .matrixRTC.enabled] | @tsv'
#   want: bluevulpine.net  synapse_bluevulpine  synapse_bluevulpine  mas_bluevulpine  mas_bluevulpine  false  false  false
```

Then the chart render (proves the values are accepted and every object is namespaced):

```bash
tmp="$(mktemp -d)"
tag="$(yq '.spec.ref.tag' kubernetes/apps/matrix-bluevulpine/matrix-stack/app/ocirepository.yaml)"
helm pull oci://ghcr.io/element-hq/ess-helm/matrix-stack --version "$tag" -d "$tmp"
echo "$app" | yq 'select(.kind=="HelmRelease") | .spec.values' > "$tmp/values.yaml"
helm template matrix-stack "$tmp"/matrix-stack-*.tgz -n matrix-bluevulpine -f "$tmp/values.yaml" > "$tmp/out.yaml"
yq -e 'select(.kind=="ConfigMap" and .metadata.name=="matrix-stack-well-known") | .data' "$tmp/out.yaml" | grep -E 'matrix.bluevulpine.net:443|https://matrix.bluevulpine.net'   # want both
grep -c 'element-web' "$tmp/out.yaml"                                                          # want 0
grep -E 'server_name: *"?bluevulpine.net' "$tmp/out.yaml" | head -1                            # want a match
yq 'select(.metadata.namespace != null and .metadata.namespace != "matrix-bluevulpine") | .kind + "/" + .metadata.name' "$tmp/out.yaml"  # want empty
```

If the `matrix-stack-well-known` ConfigMap name or keys differ in this chart version, find the delegation object with `grep -n -B3 -A10 'm.server' "$tmp/out.yaml"` and assert against that instead. The assertion that matters is the two values, not the object name.

- [ ] **Step 2: Run it to verify it fails**

Expected: `kustomize build` errors, because `app/` doesn't exist.

- [ ] **Step 3: Implement**

`app/ocirepository.yaml`: copy `kubernetes/apps/matrix/matrix-stack/app/ocirepository.yaml` **unchanged**. That keeps the same tag, so Renovate bumps both releases in one PR. If #2002 has merged, it reads `26.9.4`.

`app/pvc.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.36.2-standalone-strict/persistentvolumeclaim-v1.json
# Synapse media. A PLAIN claim, deliberately not components/volsync-claim: that
# component pins a dataSourceRef to a VolSync ReplicationDestination
# (${APP}-dst-local) which a kopiur-only app never creates. It exists to keep
# MIGRATING PVCs byte-identical, and this one has nothing to migrate.
#
# Consequence: delete-and-recreate comes up EMPTY. Recovery is a manual kopiur
# Restore (README). The planned components/kopiur-claim is the eventual fix.
#
# longhorn-2-replica: chosen at creation, where it is free; changing it later
# means the re-bind procedure (reference_longhorn_sc_rebind_no_restore).
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: synapse-media
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: longhorn-2-replica
```

`app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./externalsecret.yaml
  - ./helmrelease.yaml
  - ./pvc.yaml
  - ./httproute.yaml
  - ./dnsendpoint.yaml
components:
  # Backups only. The PVC is ./pvc.yaml, not components/volsync-claim (see there).
  - ../../../../components/kopiur
patches:
  # Stage snapshot restores on 1 replica. Staged PVCs otherwise inherit the source
  # class, and every local run (~12/day) would clone a 20Gi 2-REPLICA volume only
  # to read it once and delete it ("replica churn on a throwaway volume",
  # components/kopiur/local.yaml).
  - target:
      group: kopiur.home-operations.com
      kind: SnapshotPolicy
    patch: |-
      - op: add
        path: /spec/staging/storageClassName
        value: longhorn-1-replica
```

`app/externalsecret.yaml`: **copy** `kubernetes/apps/matrix/matrix-stack/app/externalsecret.yaml`, then change exactly these:

| Original | New |
| --- | --- |
| `- id: 01M3AYCYVJ7HE0FG3HPQYC0ZE7` | `- id: 01M3YQ563JRK4NR03FA7JVPD2H` |
| `issuer: "https://sso.${SECRET_DOMAIN}/application/o/matrix/"` | `issuer: "https://sso.${SECRET_DOMAIN}/application/o/matrix-bluevulpine/"` |
| comment `@<username>:${SECRET_DOMAIN}` | `@<username>:${SECRET_DOMAIN_BLOG}` |
| `key: matrix` (in `dataFrom`) | `key: matrix-bluevulpine` |

Add this comment above `dataFrom:`:

```yaml
  # THIS homeserver's own key. Extracting `matrix` here would hand this Synapse
  # derekjacobs.dev's signing key and every other secret, without any error.
```

The header comment also references the generator script. Update its usage line to `scripts/matrix-generate-secrets.sh secret/matrix-bluevulpine`.

`app/helmrelease.yaml`: **copy** `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml`. Keep all three `postRenderers` patches unchanged. Make exactly these value changes:

```yaml
    serverName: "${SECRET_DOMAIN_BLOG}"
    # (synapse.postgres)
        user: synapse_bluevulpine
        database: synapse_bluevulpine
    # (synapse.ingress)
        host: "matrix.${SECRET_DOMAIN_BLOG}"
    # (matrixAuthenticationService.postgres)
        user: mas_bluevulpine
        database: mas_bluevulpine
    # (matrixAuthenticationService.ingress)
        host: "account.${SECRET_DOMAIN_BLOG}"
```

Replace the `elementWeb:` and `elementAdmin:` blocks with:

```yaml
    # The ONE Element Web lives in the derekjacobs.dev release and serves
    # chat.${SECRET_DOMAIN_BLOG} too, via a per-host config
    # (kubernetes/apps/matrix/matrix-stack/app/element-web-bluevulpine.yaml).
    elementWeb:
      enabled: false
    elementAdmin:
      enabled: false
```

Update the file's top comment to say this is the bluevulpine.net homeserver and link the spec. Update the `existingClaim: synapse-media` comment to say `./pvc.yaml (plain claim, kopiur-backed)` and drop the Garage/step-4 sentence. The `matrixRTC: enabled: false` block stays. `wellKnownDelegation.baseDomainRedirect.enabled: false` stays.

- [ ] **Step 4: Re-run all Step 1 checks, then format**

Run all Step 1 checks, then `yamlfmt kubernetes/apps/matrix-bluevulpine`. Every check prints its `want`.

Also run the leak check:

```bash
echo "$app" | grep -n -E "key: matrix$|user: (synapse|mas)$|database: (synapse|mas)$" && echo LEAK || echo clean
```

Expected: `clean`.

- [ ] **Step 5: Commit (only if asked)**: `matrix-bluevulpine: homeserver, media volume and kopiur backups`.

---

### Task 5: Routes, apex well-known and public DNS

**Files:**
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/app/httproute.yaml`
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/app/dnsendpoint.yaml`

**Interfaces:**
- Consumes: Task 4's Services.
- Produces: public hostnames `matrix.` and `account.${SECRET_DOMAIN_BLOG}` (CNAME → `pangolin.${SECRET_DOMAIN_BLOG}`), and the apex `/.well-known/matrix` route.

- [ ] **Step 1: Write the failing check**

```bash
app="$(render kubernetes/apps/matrix-bluevulpine/matrix-stack/app "${V[@]}")"   # V from Task 4
echo "$app" | yq -e 'select(.kind=="HTTPRoute") | [.metadata.name, (.spec.hostnames|join(",")), ([.spec.parentRefs[].name]|join(","))] | @tsv'
# want exactly:
#   matrix-synapse         matrix.bluevulpine.net   internal,external-pangolin
#   matrix-synapse-lan     matrix.bluevulpine.net   internal
#   matrix-account         account.bluevulpine.net  internal
#   matrix-account-public  account.bluevulpine.net  external-pangolin
#   matrix-well-known      bluevulpine.net          external,internal
echo "$app" | yq -e 'select(.kind=="HTTPRoute" and .metadata.name=="matrix-well-known") | .spec.rules[].matches[].path | [.type, .value] | @tsv'   # want: PathPrefix  /.well-known/matrix (and nothing else)
echo "$app" | yq -e 'select(.kind=="DNSEndpoint") | .spec.endpoints[] | [.dnsName, .targets[0], .providerSpecific[0].value] | @tsv'
# want: matrix.bluevulpine.net  pangolin.bluevulpine.net  false
#       account.bluevulpine.net pangolin.bluevulpine.net  false
echo "$app" | grep -c 'derekjacobs.dev'   # want only the sso issuer line: 1
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `kustomize build` fails, because the kustomization lists files that don't exist yet.

- [ ] **Step 3: Implement**

`httproute.yaml`: **copy** `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml`, then:

1. Replace `${SECRET_DOMAIN}` with `${SECRET_DOMAIN_BLOG}` **everywhere** in the file, including the gatus annotation URL.
2. **Delete** the `matrix-element-web` and `matrix-element-admin` documents. This release serves neither.
3. In `matrix-well-known`, add the `internal` parent and replace its comment:

```yaml
# Delegation: the apex (serverName) answers /.well-known/matrix/{server,client,support};
# federation then goes to matrix.<domain>:443. ONLY that path is claimed: the blog
# (kubernetes/apps/default/bluevulpine-blog) owns everything else on the apex, and
# Gateway API gives the more specific PathPrefix to this route.
#
# BOTH gateways, unlike the derekjacobs.dev route: the blog's apex is on `external`
# AND `internal`, so on the LAN bluevulpine.net resolves to the internal gateway,
# where an external-only route would fall through to the blog's nginx and 404.
# No apex DNS change: the apex record already exists.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: matrix-well-known
spec:
  hostnames:
    - "${SECRET_DOMAIN_BLOG}"
  parentRefs:
    - name: external
      namespace: network
      sectionName: https
    - name: internal
      namespace: network
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /.well-known/matrix
      backendRefs:
        - name: matrix-stack-well-known
          port: 8010
```

4. Change the header comment's "copied from `helm template` of matrix-stack 26.9.3" so it names the tag pinned in this `ocirepository.yaml`.

`dnsendpoint.yaml`: **copy** `kubernetes/apps/matrix/matrix-stack/app/dnsendpoint.yaml`, then:
- Delete the `chat.${SECRET_DOMAIN}` endpoint. PR B adds `chat.${SECRET_DOMAIN_BLOG}` to the derekjacobs.dev file, where the Element Web lives.
- Replace `${SECRET_DOMAIN}` with `${SECRET_DOMAIN_BLOG}` in both remaining endpoints (`dnsName` and `targets`).

- [ ] **Step 4: Re-run the check, then format**

Run the Step 1 check, then `yamlfmt kubernetes/apps/matrix-bluevulpine`. Every `want` matches.

- [ ] **Step 5: Commit (only if asked)**: `matrix-bluevulpine: routes, apex well-known and public DNS`.

---

### Task 6: README

**Files:**
- Create: `kubernetes/apps/matrix-bluevulpine/matrix-stack/README.md`

- [ ] **Step 1: Write it.** Use this content (fill nothing in; every value is fixed):

````markdown
# matrix-stack (bluevulpine.net)

Second Matrix homeserver: Synapse + MAS via ESS Community `matrix-stack`. Derek's
external identity, `@bluevulpine:bluevulpine.net`. The first homeserver,
`kubernetes/apps/matrix/matrix-stack` (derekjacobs.dev), is the agent/A2A space.
Design: `docs/superpowers/specs/2026-10-02-matrix-bluevulpine-design.md`.

Mirrors the derekjacobs.dev tree. **Deviations, each deliberate:**

| What | Here | Why |
| --- | --- | --- |
| Postgres roles/DBs | `synapse_bluevulpine`, `mas_bluevulpine` | shared `postgres18`; `synapse`/`mas` are taken |
| OpenBao key | `secret/matrix-bluevulpine` | never share a key: it holds the signing key |
| Media PVC | plain `./app/pvc.yaml`, `longhorn-2-replica` | kopiur-only app; `volsync-claim`'s dataSourceRef targets a VolSync object that never exists |
| Backups | `components/kopiur`, staging on `longhorn-1-replica` | new apps are born on kopiur |
| Element Web / Admin | disabled | the shared Element Web in the derekjacobs.dev release serves `chat.bluevulpine.net` |
| Apex well-known | `external` + `internal` | LAN clients hit the internal gateway for the blog apex |

## Hosts

| Host | What | Reachable from |
| --- | --- | --- |
| `bluevulpine.net/.well-known/matrix/*` | delegation | everywhere (rest of the apex is the blog) |
| `matrix.` | Synapse client + federation API | LAN + internet (Pangolin) |
| `matrix.` `/_synapse/*` except `/_synapse/client` | Synapse admin etc. | **LAN / tailnet only** |
| `account.` | MAS (login, account, Authentik callback) | LAN + internet |
| `account.` `/api/admin` | MAS admin API | **LAN / tailnet only** (404 at the Pangolin edge) |
| `chat.` | Element Web (shared, lives in `kubernetes/apps/matrix`) | LAN + internet |

## Prerequisites (before merging)

1. **Secrets**: `./scripts/matrix-generate-secrets.sh secret/matrix-bluevulpine`
   (idempotent; `--dry-run` first).
2. **Authentik**:
   - Group `matrix-bluevulpine-users`; add `bluevulpine`.
   - OAuth2/OpenID Provider "Provider for Matrix (bluevulpine.net)", confidential,
     with the same authorization/invalidation flows, property mappings, signing
     key, `sub_mode: user_username` and `issuer_mode: per_provider` as "Provider
     for Matrix".
     - Redirect URI (strict):
       `https://account.bluevulpine.net/upstream/callback/01M3YQ563JRK4NR03FA7JVPD2H`
   - Application `matrix-bluevulpine` (slug exactly that) with that provider.
     Bind the group to it.
3. **Client credentials**:
   `bao kv patch secret/matrix-bluevulpine Mas__Authentik__ClientId='…' Mas__Authentik__ClientSecret='…'`
   (single quotes).
4. **Pangolin**, only **after** each CNAME resolves publicly: HTTP resources for
   `matrix.` and `account.bluevulpine.net`, targeting the `external-pangolin`
   gateway like the other Pangolin apps. If a geo rule is added on `matrix.`, it
   must exempt `/_matrix/federation/*` and `/_matrix/key/*`.

The ULID is fixed and is part of the redirect URI. **Never change it.**

## Verify

```bash
curl -s https://bluevulpine.net/.well-known/matrix/server   # {"m.server": "matrix.bluevulpine.net:443"}
curl -s https://bluevulpine.net/.well-known/matrix/client   # m.homeserver.base_url
curl -s https://matrix.bluevulpine.net/_matrix/client/versions
curl -s -o /dev/null -w '%{http_code}\n' https://matrix.bluevulpine.net/_synapse/admin/v1/server_version  # outside the LAN: 404
curl -s -o /dev/null -w '%{http_code}\n' https://bluevulpine.net/   # the blog: still 200
kubectl -n matrix-bluevulpine get snapshots.kopiur.home-operations.com   # first of each leg: Succeeded
```

Then <https://federationtester.matrix.org/#bluevulpine.net>.

**Cert check:** a new Pangolin host can be stuck on Traefik's self-signed fallback
if its resource was created before DNS resolved. If the issuer is
`TRAEFIK DEFAULT CERT`, restart Traefik on the VPS:
`echo | openssl s_client -connect matrix.bluevulpine.net:443 -servername matrix.bluevulpine.net | openssl x509 -noout -issuer`

## Operations

**Rotating a database password.** Same order as the derekjacobs.dev README, with
`-n matrix-bluevulpine` and `secret/matrix-bluevulpine`.

**Media recovery.** The PVC has no `dataSourceRef`, so if it is deleted and
recreated it comes up **empty**. Restore by hand from kopiur. Snapshot identity:
`synapse-media@matrix-bluevulpine:/data`, in `kopia-local` and `kopia-r2`.

**Rollback.** Revert the PR. Deleting the Kustomizations by hand doesn't stick,
because `cluster-apps` recreates them. Reverting prunes the media PVC, **and with
it the data** (`reclaimPolicy: Delete`). What survives:
- kopia snapshots
- the Postgres databases
- the OpenBao key
- the namespace
````

- [ ] **Step 2: Check it**

Run: `grep -n -i -E 'TBD|TODO|<fill|xxx' kubernetes/apps/matrix-bluevulpine/matrix-stack/README.md`
Expected: no output.

- [ ] **Step 3: Commit (only if asked)**: `matrix-bluevulpine: README`.

---

### Task 7: Validate PR A as a whole and open it (unmerged)

**Files:** none new.

- [ ] **Step 1: Whole-repo Flux render**

Run: `flux-local test --enable-helm --path kubernetes/flux/cluster`
Expected: passes. If it fails, compare against `main` before blaming this change: the 2026-09 Hindsight notes record a pre-existing `MalformedYAMLError` elsewhere in the repo. Only failures under `matrix-bluevulpine/`, `kopiur-system/` or `scripts/` are this PR's.

- [ ] **Step 2: Schema validation**

```bash
for d in kubernetes/apps/matrix-bluevulpine/matrix-stack/db kubernetes/apps/matrix-bluevulpine/matrix-stack/app kubernetes/apps/kopiur-system/repositories/app; do
  render "$d" "${V[@]}" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -summary
done
```

Expected: `Invalid: 0, Errors: 0` for each. Skipped CRDs are acceptable.

- [ ] **Step 3: Staged pre-commit**

Run: `git add -A docs/superpowers kubernetes/apps/matrix-bluevulpine kubernetes/apps/kopiur-system scripts && lefthook run pre-commit`
Expected: yamlfmt makes no changes and gitleaks is clean. Never use `--all-files`.

- [ ] **Step 4: Open the PR (only if Derek asks)**

Push the branch, then run `~/.buzz/bin/gh-as-fizz.sh pr create --draft --title 'matrix-bluevulpine: second homeserver for bluevulpine.net' --body-file <file>`. The body states:
- It is safe to merge only after Task 8.
- It is part 1 of 2.
- It links the spec.
- It ends with the 🤖 attribution line and the session URL.

It must **not** be merged here.

---

### Task 8: Prerequisites (Derek acts; the agent verifies)

**Files:** none.

- [ ] **Step 1: Generate secrets.** Derek runs `./scripts/matrix-generate-secrets.sh --dry-run secret/matrix-bluevulpine`, then the same command without `--dry-run`. The agent can't verify field values without reading OpenBao, so Derek confirms the output ends with `Wrote N field(s)` plus the two `MISSING Mas__Authentik__*` lines.

- [ ] **Step 2: Authentik (Derek, by hand)**, per the README's Prerequisites step 2. The agent then verifies **read-only** via the bootstrap token, in an ephemeral in-cluster pod, printing only non-secret fields:

```bash
TOKEN=$(kubectl -n identity get secret authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl -n identity run ak-verify --rm -i --restart=Never --image=python:3.13-alpine --command -- python3 -c "
import json,urllib.request
B='http://authentik-server.identity.svc.cluster.local/api/v3'; H={'Authorization':'Bearer ${TOKEN}'}
g=lambda p: json.load(urllib.request.urlopen(urllib.request.Request(B+p,headers=H)))
p=g('/providers/oauth2/?search=bluevulpine')['results'][0]
print('client_type', p['client_type'], '| sub_mode', p['sub_mode'], '| issuer_mode', p['issuer_mode'])
print('redirects', [r['url'] for r in p['redirect_uris']])
a=g('/core/applications/matrix-bluevulpine/'); print('app provider ok', a['provider']==p['pk'])
b=g('/policies/bindings/?target='+a['pk'])['results']; print('bindings', [x['group_obj']['name'] for x in b if x.get('group_obj')])
grp=g('/core/groups/?name=matrix-bluevulpine-users')['results'][0]; print('members', grp['users_obj'] and [u['username'] for u in grp['users_obj']])
" 2>&1 | grep -v -E '^(Warning|All commands|If you|warning|pod )'
```

Expected output:
- `client_type confidential | sub_mode user_username | issuer_mode per_provider`
- redirects `['https://account.bluevulpine.net/upstream/callback/01M3YQ563JRK4NR03FA7JVPD2H']`
- `app provider ok True`
- bindings `['matrix-bluevulpine-users']`
- members `['bluevulpine']`

- [ ] **Step 3: Client credentials (Derek)**: `bao kv patch secret/matrix-bluevulpine Mas__Authentik__ClientId='…' Mas__Authentik__ClientSecret='…'`.

- [ ] **Step 4: Hash check 1, OpenBao vs Authentik (agent, read-only)**

The rendered Secret doesn't exist yet. Hash the Authentik side the way it was done on 2026-09-26, in an ephemeral pod, printing only the hash:

```bash
TOKEN=$(kubectl -n identity get secret authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl -n identity run ak-hash --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c \
 "curl -s -H 'Authorization: Bearer ${TOKEN}' 'http://authentik-server.identity.svc.cluster.local/api/v3/providers/oauth2/?search=bluevulpine' \
  | sed -E 's/.*\"client_secret\":\"([^\"]+)\".*/\1/' | tr -d '\n' | sha256sum" 2>&1 | grep -E '^[0-9a-f]{64}'
```

The agent **cannot** read OpenBao: the sandbox classes it as credential materialization. Derek runs the OpenBao side and compares the two hashes himself:

```bash
bao kv get -field=Mas__Authentik__ClientSecret secret/matrix-bluevulpine | tr -d '\n' | shasum -a 256
```

Expected: identical hashes. **Gate:** do not merge PR A on a mismatch.

- [ ] **Step 5: Open questions the review left (agent, read-only)**
- Does ESO's OpenBao policy allow the new key? After merge, the ExternalSecret `matrix-stack-secret` reaching `SecretSynced` answers that. Before merge, check whether other recently added keys use a wildcard path: `kubectl get clustersecretstore openbao -o yaml` (store metadata only).
- Is bluevulpine.net a Pangolin domain already? `ssh root@pangolin` is read-only here; ask Derek to check the Pangolin dashboard's domain list. If it isn't, he adds it before Task 10.

---

### Task 9: Merge PR A (Derek) and verify the homeserver

**Files:** none.

- [ ] **Step 1: Derek merges** (the sandbox blocks the agent from merging). Pushing to `main` auto-reconciles through the webhook. **Do not** run `flux reconcile`.

- [ ] **Step 2: Expect and wait out the kopiur-repositories transient**

```bash
flux -n kopiur-system get ks kopiur-repositories
flux -n matrix-bluevulpine get ks
```

Expected eventually: all `Ready True`. A first `kopiur-repositories` failure of the form `namespaces "matrix-bluevulpine" not found` is expected and clears on its 2m retry. Re-check before debugging.

- [ ] **Step 3: Database, pods, secrets**

```bash
kubectl -n matrix-bluevulpine get job,pods,externalsecret,pvc
kubectl -n matrix-bluevulpine logs job/matrix-db-init -c assert-synapse-locale
```

Expected:
- The Job is `Complete`, and its log reads `synapse_bluevulpine database collation/ctype is C/C`.
- Pods `matrix-stack-synapse-main-0`, `…matrix-authentication-service-…` and `…haproxy-…` are `Running`.
- All ExternalSecrets (`matrix-stack-secret`, `matrix-db-init-secret`, `kopiur-local`, `kopiur-r2`) are `SecretSynced`.
- PVC `synapse-media` is `Bound` on `longhorn-2-replica`.

- [ ] **Step 4: Hash check 2, rendered Secret vs Authentik.** Extract **only** the `client_secret:` line:

```bash
kubectl -n matrix-bluevulpine get secret matrix-stack-secret -o jsonpath='{.data.mas-upstream-authentik\.yaml}' \
  | base64 -d | grep -E '^\s*client_secret:' | sed -E 's/.*client_secret: "([^"]+)".*/\1/' | tr -d '\n' | sha256sum
```

Expected: equals Task 8's Authentik hash.

- [ ] **Step 5: Identity sanity (no borrowed secrets).** The new signing key's id must differ from derekjacobs.dev's. Only key *ids* are compared, and they are public in each server's `/_matrix/key/v2/server`:

```bash
kubectl -n matrix-bluevulpine exec matrix-stack-synapse-main-0 -- curl -s localhost:8008/_matrix/key/v2/server | jq -r '.server_name, (.verify_keys|keys[])'
curl -s https://matrix.derekjacobs.dev/_matrix/key/v2/server | jq -r '.server_name, (.verify_keys|keys[])'
```

Expected: `bluevulpine.net` and `derekjacobs.dev`, each with a **different** `ed25519:a_xxxx` key id. **Gate:** if the key ids match, stop.

- [ ] **Step 6: Apex well-known, LAN and public; blog unaffected**

```bash
curl -s https://bluevulpine.net/.well-known/matrix/server                        # LAN view
curl -s --resolve bluevulpine.net:443:$(dig +short bluevulpine.net @1.1.1.1 | head -1) \
     https://bluevulpine.net/.well-known/matrix/server                           # public (CF edge) view
curl -s -o /dev/null -w '%{http_code}\n' https://bluevulpine.net/                # blog: 200
```

Expected: both show `{"m.server": "matrix.bluevulpine.net:443"}`, and the blog returns `200`.

- [ ] **Step 7: First backup of each leg succeeds**

```bash
kubectl -n matrix-bluevulpine get snapshotpolicies,snapshotschedules
kubectl -n matrix-bluevulpine get snapshots.kopiur.home-operations.com -o custom-columns=NAME:.metadata.name,POLICY:.spec.policyRef.name,PHASE:.status.phase
```

Expected: a `synapse-media-local` Snapshot in phase `Succeeded` within about 2h, and `synapse-media-r2` the next morning after 06:xx UTC. **A `Pending` Snapshot is a failure, not progress.** Check `kubectl describe` for `PrivilegedMoverNotPermitted`; if it's there, the namespace annotation is missing.

---

### Task 10: Pangolin resources and certificates

**Files:** none.

- [ ] **Step 1: Wait for public DNS**

Run: `for h in matrix account; do dig +short $h.bluevulpine.net @1.1.1.1; done`
Expected: each prints `pangolin.bluevulpine.net.` and `134.209.70.159`.

- [ ] **Step 2: Derek creates the Pangolin HTTP resources** for `matrix.` and `account.bluevulpine.net`, targeting the `external-pangolin` gateway, the same way as the other Pangolin apps.

- [ ] **Step 3: Verify real certs**

```bash
for h in matrix account; do echo | openssl s_client -connect $h.bluevulpine.net:443 -servername $h.bluevulpine.net 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName; done
```

Expected: issuer Let's Encrypt, with SAN equal to the hostname. If either shows `TRAEFIK DEFAULT CERT`, restart Traefik with `ssh root@pangolin "docker restart traefik"` (Derek approves), then re-check.

- [ ] **Step 4: README verify block**: run all of it (Task 6). The admin API returns `404` from outside, and `/_matrix/client/versions` returns JSON.

---

### Task 11 (PR B): Shared Element Web serves chat.bluevulpine.net

Changes the **live** derekjacobs.dev release. Start only after Task 10 passes.

**Files:**
- Create: `kubernetes/apps/matrix/matrix-stack/app/element-web-bluevulpine.yaml`
- Modify: `kubernetes/apps/matrix/matrix-stack/app/kustomization.yaml` (resources)
- Modify: `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml` (append to `postRenderers[0].kustomize.patches`)
- Modify: `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml` (`matrix-element-web` hostnames)
- Modify: `kubernetes/apps/matrix/matrix-stack/app/dnsendpoint.yaml` (one endpoint)
- Modify: `kubernetes/apps/matrix/matrix-stack/README.md` (hosts table row for `chat.`)

**Interfaces:**
- Consumes: Task 4's `matrix.bluevulpine.net` homeserver.
- Produces: `https://chat.bluevulpine.net/config.chat.bluevulpine.net.json`, which defaults the client to bluevulpine.net.

- [ ] **Step 1: Write the failing check**

Use the existing instance's real substitutions, copied from its `ks.yaml` (`APP=synapse-media`, `NS=matrix` and its `VOLSYNC_*` values):

```bash
W=(APP=synapse-media NS=matrix VOLSYNC_CAPACITY=20Gi VOLSYNC_STORAGECLASS=longhorn-1-replica VOLSYNC_CLONE_STORAGECLASS=longhorn-1-replica \
   VOLSYNC_SNAPSHOTCLASS=longhorn-snapclass VOLSYNC_ACCESSMODES=ReadWriteOnce VOLSYNC_COPYMETHOD=Snapshot \
   VOLSYNC_RUN_AS_USER=10091 VOLSYNC_RUN_AS_GROUP=10091 VOLSYNC_FS_GROUP=10091 \
   VOLSYNC_LOCAL_SCHEDULE='47 */2 * * *' VOLSYNC_R2_SCHEDULE='45 6 * * *')
old="$(render kubernetes/apps/matrix/matrix-stack/app "${W[@]}")"
echo "$old" | yq -e 'select(.kind=="ConfigMap" and .metadata.name=="element-web-bluevulpine") | .data | keys | .[]'   # want: config.chat.bluevulpine.net.json
echo "$old" | yq -e 'select(.kind=="ConfigMap" and .metadata.name=="element-web-bluevulpine") | .data["config.chat.bluevulpine.net.json"]' \
  | jq -e '.default_server_config["m.homeserver"] == {"base_url":"https://matrix.bluevulpine.net","server_name":"bluevulpine.net"}'   # want true
echo "$old" | yq -e 'select(.kind=="HTTPRoute" and .metadata.name=="matrix-element-web") | .spec.hostnames | join(",")'   # want: chat.derekjacobs.dev,chat.bluevulpine.net
echo "$old" | yq -e 'select(.kind=="DNSEndpoint") | .spec.endpoints[] | select(.dnsName=="chat.bluevulpine.net") | .targets[0]'   # want: pangolin.bluevulpine.net
```

Then render the Element Web Deployment through the postRenderer. A HelmRelease patch can't be exercised by `kustomize build`, so use flux-local:

```bash
flux-local get hr -n matrix --path kubernetes/flux/cluster --enable-helm -o yaml 2>/dev/null \
  | yq -e 'select(.kind=="Deployment" and .metadata.name=="matrix-stack-element-web") |
     [ (.metadata.annotations["configmap.reloader.stakater.com/reload"]),
       (.spec.template.spec.containers[] | select(.name=="element-web") | .volumeMounts[] | select(.subPath=="config.chat.bluevulpine.net.json") | .mountPath) ] | @tsv'
# want: element-web-bluevulpine   /app/config.chat.bluevulpine.net.json
```

If `flux-local get hr` doesn't render post-renderer output in this version, use this fallback. Save the base `helm template` (Task 4 method, values from `$old`) to `$tmp/base.yaml`. Write a throwaway `kustomization.yaml` in `$tmp` whose `resources: [base.yaml]` and whose `patches:` are the HelmRelease's `postRenderers[0].kustomize.patches` (`yq` them out). Run `kustomize build "$tmp"`, then apply the same `yq` assertion.

- [ ] **Step 2: Run it to verify it fails**

Expected: the first `yq` fails, because there's no such ConfigMap.

- [ ] **Step 3: Get the live base config**

```bash
kubectl -n matrix get cm matrix-stack-element-web -o jsonpath='{.data.config\.json}' | jq .
```

The new file is that exact JSON with **only** `default_server_config` changed.

- [ ] **Step 4: Implement**

`element-web-bluevulpine.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.36.2-standalone-strict/configmap-v1.json
# Per-hostname Element Web config: the one Element Web serves chat.${SECRET_DOMAIN_BLOG}
# too, defaulting it to the bluevulpine.net homeserver
# (kubernetes/apps/matrix-bluevulpine). Element loads config.<window.location.hostname>.json
# and falls back to config.json on 404. It does NOT merge the two: this file
# REPLACES config.json for that host.
#
# DRIFT: a copy of the chart-rendered config.json with only default_server_config
# changed. On chart upgrades, re-diff it against
#   kubectl -n matrix get cm matrix-stack-element-web -o jsonpath='{.data.config\.json}'
# the same way the HTTPRoute paths are re-diffed.
#
# Mounted by the 4th postRenderer patch in ./helmrelease.yaml, which also adds the
# Reloader annotation. Element's entrypoint copies /app/config*.json once at start,
# so an edit here takes effect only through that restart.
apiVersion: v1
kind: ConfigMap
metadata:
  name: element-web-bluevulpine
data:
  config.chat.${SECRET_DOMAIN_BLOG}.json: |
    <the Step 3 JSON, pretty-printed, with:
      "default_server_config": {
        "m.homeserver": {
          "base_url": "https://matrix.${SECRET_DOMAIN_BLOG}",
          "server_name": "${SECRET_DOMAIN_BLOG}"
        }
      }>
```

The `<…>` above is the one instruction in this plan that must be replaced, not copied. The executor pastes the Step 3 JSON verbatim with only `default_server_config` changed. It isn't inlined because the chart owns it, and the copy has to come from the chart version actually running at execution time.

`kustomization.yaml`: add `- ./element-web-bluevulpine.yaml` to `resources` after `./helmrelease.yaml`. Use a plain resource, not a `configMapGenerator`, so the name has no hash suffix: the postRenderer patch refers to it by literal name.

`helmrelease.yaml`: append to `postRenderers[0].kustomize.patches`:

```yaml
          # Serve chat.${SECRET_DOMAIN_BLOG} from this Element Web with its own
          # default homeserver (./element-web-bluevulpine.yaml). Strategic merge adds
          # a volume and a subPath mount next to the chart's config.json; Reloader
          # restarts the pod on ConfigMap edits, which is the only way they apply,
          # because the entrypoint copies /app/config*.json once at start.
          - target:
              kind: Deployment
              name: matrix-stack-element-web
            patch: |-
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: matrix-stack-element-web
                annotations:
                  configmap.reloader.stakater.com/reload: element-web-bluevulpine
              spec:
                template:
                  spec:
                    volumes:
                      - name: config-bluevulpine
                        configMap:
                          name: element-web-bluevulpine
                    containers:
                      - name: element-web
                        volumeMounts:
                          - name: config-bluevulpine
                            mountPath: /app/config.chat.${SECRET_DOMAIN_BLOG}.json
                            subPath: config.chat.${SECRET_DOMAIN_BLOG}.json
                            readOnly: true
```

`httproute.yaml`, in `matrix-element-web`:

```yaml
  hostnames:
    - "chat.${SECRET_DOMAIN}"
    # Same Element Web, defaulting to the bluevulpine.net homeserver via
    # ./element-web-bluevulpine.yaml.
    - "chat.${SECRET_DOMAIN_BLOG}"
```

`dnsendpoint.yaml`: append

```yaml
    # chat.${SECRET_DOMAIN_BLOG}: the shared Element Web (see ./element-web-bluevulpine.yaml).
    - dnsName: "chat.${SECRET_DOMAIN_BLOG}"
      recordType: CNAME
      targets:
        - "pangolin.${SECRET_DOMAIN_BLOG}"
      providerSpecific:
        - name: external-dns.alpha.kubernetes.io/cloudflare-proxied
          value: "false"
```

README: in the hosts table, change the `chat.` row to `Element Web — also serves chat.bluevulpine.net (bluevulpine.net homeserver), see app/element-web-bluevulpine.yaml`.

- [ ] **Step 5: Re-run all Step 1 checks, then validate**

Run all Step 1 checks, then Task 7's Steps 1–3 for these paths. Every `want` matches, and nothing else in the existing render changes:

```bash
diff <(git show HEAD:kubernetes/apps/matrix/matrix-stack/app/httproute.yaml) kubernetes/apps/matrix/matrix-stack/app/httproute.yaml
```

That should be only the hostname lines.

- [ ] **Step 6: PR B (only if asked)**: `matrix: serve chat.bluevulpine.net from the shared Element Web`, a draft via `gh-as-fizz.sh`, linking PR A.

- [ ] **Step 7: After Derek merges, verify live**

```bash
kubectl -n matrix rollout status deploy/matrix-stack-element-web
for h in chat.derekjacobs.dev chat.bluevulpine.net; do
  curl -s https://$h/config.$h.json | jq -r '.default_server_config["m.homeserver"].server_name // "fallback-to-config.json"'
done
```

Expected: `fallback-to-config.json` for derekjacobs.dev (no per-host file; falls back to `config.json`), and `bluevulpine.net` for bluevulpine.net. Also confirm `curl -s https://chat.derekjacobs.dev/config.json | jq -r '.default_server_config["m.homeserver"].server_name'` returns `derekjacobs.dev`, so the existing host is unchanged.

- [ ] **Step 8: Pangolin + cert + first sign-in**: after `dig +short chat.bluevulpine.net @1.1.1.1` resolves, Derek creates the Pangolin resource, and the agent runs the Task 10 Step 3 cert check for `chat.`. Derek then signs in at `https://chat.bluevulpine.net`. Expected: Authentik, then a user `@bluevulpine:bluevulpine.net`. The agent confirms it in MAS logs (`kubectl -n matrix-bluevulpine logs deploy/matrix-stack-matrix-authentication-service --since=10m | grep -E 'upstream/callback|/oauth2/token'`): a 200/302 callback, and no `invalid_client`.

---

### Task 12: Close derekjacobs.dev's open door

**Files:** none (Authentik by hand).

- [ ] **Step 1 (Derek):** add `bluevulpine` to group `matrix-users`. **Membership first.**
- [ ] **Step 2 (agent, read-only):** confirm the membership via Task 8's Step 2 script, adapted to `name=matrix-users`. Expected: `members ['bluevulpine']`.
- [ ] **Step 3 (Derek):** bind `matrix-users` to application `matrix`.
- [ ] **Step 4 (Derek, agent watches MAS logs in `-n matrix`):** sign out and back in at `chat.derekjacobs.dev`. Expected: success. If it's refused, Derek removes the binding at once (that restores the old allow-all), and we debug from there.

---

### Task 13: Federation

**Files:** none.

- [ ] **Step 1:** <https://federationtester.matrix.org/#bluevulpine.net> reports all checks green. If the Cloudflare-proxied apex is challenged from the tester's datacenter IP (the one open question from the review), the `.well-known` check fails while LAN and residential curls pass. In that case, add a Cloudflare WAF skip rule for `/.well-known/matrix/*` (Derek, in the Cloudflare dashboard).
- [ ] **Step 2:** From `@bluevulpine:bluevulpine.net`, join a small public room first (not `#matrix:matrix.org`). Expected: the join succeeds and history loads.
- [ ] **Step 3:** Update Hindsight via `hindsight_capture_initiative` with `relates_to_page_id: kp-041afcf963974c628e816bd56b39c655`: built and live, plus anything that deviated from this plan.
