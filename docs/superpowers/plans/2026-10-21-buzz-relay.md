# Buzz Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a private, self-hosted Buzz relay at `buzz.${SECRET_DOMAIN}` in the `ai` namespace, so agent-to-agent traffic and DMs are readable only by us, not by Block's hosted service.

**Architecture:** Block's upstream Helm chart (`oci://ghcr.io/block/buzz/charts/buzz`) is deployed by a Flux HelmRelease with every bundled service off. State is on the shared CNPG `postgres18` (via a `postgres-init` init container), pub/sub on the shared Dragonfly, and media plus git objects in a dedicated Garage bucket. The pod is otherwise stateless: no PVC, no volsync. Exposure is the internal Envoy gateway plus tailnet only.

**Tech Stack:** Flux v2 (HelmRelease + OCIRepository), Buzz chart 0.1.11, `ghcr.io/block/buzz`, CNPG, Dragonfly, Garage S3, OpenBao + External Secrets, Envoy Gateway HTTPRoute.

**Spec:** `docs/briefs/2026-10-02-paperclip-workload.md`, sections "Buzz relay (self-hosted)" and "Matrix vs Buzz for agent-to-agent" (PR #2231). Chart reference: `deploy/charts/buzz/{values.yaml,README.md,examples/flux-helmrelease.yaml}` in `block/buzz`.

**Namespace decision: `ai`.** Considered `matrix` and a new `comms` namespace. `ai` wins:
- Dragonfly's NetworkPolicy already admits it (`dragonfly-allow-ai`), so it needs no new policy.
- The first clients (`hermes`, later Paperclip) live there, so relay traffic stays in-namespace.
- The relay is an internal agent bus, not a public federated service like `matrix`.
- A `comms` namespace holding one app adds a kustomization, a dragonfly policy and PSA labels for no gain. Revisit if Matrix and Buzz ever share bridges.

## Global Constraints

- Every manifest starts with `---` and a `# yaml-language-server: $schema=` URL that returns JSON (check with `curl -s <url> | head -c1` → `{`). Must pass `yamlfmt`; block-style arrays.
- Do not add `install.strategy`/`upgrade.strategy` or `crds:` to the HelmRelease (injected by `cluster-apps`).
- No Renovate annotation on the HelmRelease's top-level `image.tag` (the `flux` manager detects it; an annotation causes duplicate PRs) or on the OCIRepository tag.
- Secrets only from OpenBao via `ExternalSecret` (`ClusterSecretStore` `openbao`, `engineVersion: v2`). OpenBao key `secret/buzz`, fields PascalCase double-underscore.
- `dependsOn` names exactly: `cloudnative-pg-cluster18` (ns `database`), `external-secrets-openbao-store` (ns `external-secrets`), `dragonfly-cluster` (ns `database`).
- Postgres via `INIT_POSTGRES_*` (superuser from the shared `cloudnative-pg` key → `{{ .Postgres__SuperPassword }}`). Passwords hex only (`openssl rand -hex 32`); `postgres-init` single-quotes them in SQL.
- Redis keys are already namespaced by Buzz (`buzz:{community}:…`); do not use a Redis DB number (Dragonfly runs `--cluster_mode=emulated`, where `SELECT` isolation is unreliable).
- Internal gateway only (`parentRefs: internal/network`, `sectionName: https`). No `external`/`external-pangolin` route in this plan: the relay has no rate limiting yet (`ARCHITECTURE.md`).
- Never regenerate `Buzz__RelayPrivateKey` (relay identity) once written.
- Commit subjects and the PR title use Scoped Commits (`buzz: …`, lowercase; no `feat:`/`docs:` type and no `(scope)`), per `CLAUDE.md`. Agent commits use per-command author flags and trailers per `CLAUDE.md` "Commit authorship".

## Review Focus

1. **Node drain with one replica.** The chart's PDB defaults to `minAvailable: 1`, which blocks every Talos drain/upgrade. Expect drains to proceed: set `podDisruptionBudget.enabled: false`. Test in Task 3.
2. **Garage rejects conditional PUTs.** The relay's git conformance probe is startup-fatal. Expect a decided, documented outcome (probe passes, or probe off with git hosting declared unsupported), never a crash-looping pod. Task 1 decides it; Task 3 renders the decision.
3. **Long-lived WebSockets cut by the gateway.** Expect a desktop/agent connection to stay open for hours without reconnect storms. Verify in Task 4 (connection age > 1h); if cut, add an Envoy `BackendTrafficPolicy`/`ClientTrafficPolicy` idle timeout.
4. **Secret rotation not picked up.** The chart's Deployment has no Reloader annotation. Expect an ExternalSecret change to roll the pod: add one through a `postRenderers` patch. Test in Task 3.
5. **Desktop/relay version skew.** Desktop is v0.5.x while the newest relay release tag is `0.2.1` (`main-*` tags ship daily). Expect the desktop app to connect, auth (NIP-42) and post. Task 1 picks the tag that works; Task 4 verifies.

---

### Task 1: Spike — admit Garage, Dragonfly and an image tag

Gate for the rest of the plan. Results go in `kubernetes/apps/ai/buzz/README.md` (created here).

**Files:**
- Create: `kubernetes/apps/ai/buzz/README.md`

**Interfaces:**
- Produces: `GIT_PROBE` = `on` | `off`; `BUZZ_IMAGE_TAG` (a concrete tag, never `main`/`latest`); confirmation that Dragonfly accepts `PSUBSCRIBE`. Task 3 consumes all three.

- [ ] **Step 1: Create the Garage bucket and a per-app key** (operator, on the Garage host):

```bash
garage bucket create buzz-media
garage key create buzz
garage bucket allow --read --write --owner buzz-media --key buzz
```

Expected: key id `GK…` and secret printed once. Store them: `bao kv patch secret/buzz Buzz__Garage__AccessKey=GK… Buzz__Garage__SecretKey=…`.

- [ ] **Step 2: Run the relay's conformance probe against Garage** from a workstation with Docker (no Postgres needed to reach the probe; it runs before serving):

```bash
docker run --rm -e BUZZ_S3_ENDPOINT="$GARAGE_S3_ENDPOINT" -e BUZZ_S3_BUCKET=buzz-media \
  -e BUZZ_S3_REGION=us-east-1 -e BUZZ_S3_ADDRESSING_STYLE=path \
  -e BUZZ_S3_ACCESS_KEY=GK… -e BUZZ_S3_SECRET_KEY=… -e BUZZ_GIT_CONFORMANCE_PROBE=true \
  -e BUZZ_RELAY_PRIVATE_KEY="$(openssl rand -hex 32)" -e RELAY_URL=ws://localhost:3000 \
  -e DATABASE_URL=postgres://x:x@127.0.0.1:1/x -e REDIS_URL=redis://127.0.0.1:1 \
  ghcr.io/block/buzz:0.2.1 2>&1 | grep -iE 'conformance|probe|s3' | head -20
```

Expected: a log line reporting the probe passed (then a DB connection error, which is fine), or a probe failure naming the axiom. Record pass → `GIT_PROBE=on`; failure → `GIT_PROBE=off`, and write in the README that Buzz-hosted git repos are unsupported here (NIP-34 patch events still work; they live in Postgres). If startup ordering means the probe never runs before the DB error, repeat this inside Task 4's first boot instead and record the result there.

- [ ] **Step 3: Confirm Dragonfly pub/sub from the `ai` namespace:**

```bash
kubectl -n ai run df-test --rm -it --restart=Never --image=redis:7-alpine -- \
  sh -c 'redis-cli -h dragonfly.database.svc.cluster.local PUBSUB NUMPAT && timeout 3 redis-cli -h dragonfly.database.svc.cluster.local PSUBSCRIBE "buzz:*"; echo rc=$?'
```

Expected: an integer for `NUMPAT`, then `psubscribe buzz:* 1` before the timeout (`rc=124`). An error such as `unknown command` blocks the plan; fall back to a dedicated Dragonfly instance (new task, out of scope here).

- [ ] **Step 4: Choose `BUZZ_IMAGE_TAG`.** Install the Buzz desktop version you use today, point it at a local relay started from `deploy/compose` with `BUZZ_IMAGE=ghcr.io/block/buzz:0.2.1`, sign in and post. If it fails with a protocol or kind error, retry with the newest `main-<yyyymmddhhmmss>-<sha>` tag (`crane ls ghcr.io/block/buzz | grep ^main- | sort | tail -1`). Record the working tag and the desktop version in the README.

- [ ] **Step 5: Commit** `kubernetes/apps/ai/buzz/README.md`, with sections: purpose (one paragraph, link to the brief), "Admission results" (GIT_PROBE, Dragonfly, image tag + desktop version, date), "First deploy" (filled in Task 4).

```bash
git add kubernetes/apps/ai/buzz/README.md
git commit -m "buzz: record garage, dragonfly and image admission results"
```

---

### Task 2: OpenBao secrets script

**Files:**
- Create: `scripts/buzz-generate-secrets.sh` (executable)

**Interfaces:**
- Produces OpenBao `secret/buzz` fields, consumed verbatim by Task 3's ExternalSecret:
  `Buzz__RelayPrivateKey` (64 hex), `Buzz__GitHookHmacSecret` (64 hex), `Buzz__Postgres__User` (`buzz`), `Buzz__Postgres__Password` (64 hex), `Buzz__Postgres__DbName` (`buzz`). `Buzz__Garage__AccessKey` / `Buzz__Garage__SecretKey` come from Task 1, step 1. The script only reports them if missing.

- [ ] **Step 1: Write the script,** modelled on `scripts/matrix-generate-secrets.sh`: same `bao token lookup` guard, same "only *No value found* counts as missing" read logic, `--dry-run`, and never overwriting an existing field. Generate with `openssl rand -hex 32`. Write with `bao kv patch` (or `put` when the path does not exist). Report missing Garage fields and exit 0.

- [ ] **Step 2: Verify the guard and idempotence**

Run: `shellcheck scripts/buzz-generate-secrets.sh && ./scripts/buzz-generate-secrets.sh --dry-run`
Expected: shellcheck clean; dry run lists the five generated fields as "would create" on first run. After a real run, a second `--dry-run` lists all of them as "exists, kept".

- [ ] **Step 3: Commit**

```bash
git add scripts/buzz-generate-secrets.sh
git commit -m "buzz: add idempotent openbao secret generator"
```

---

### Task 3: Flux manifests

**Files:**
- Create: `kubernetes/apps/ai/buzz/ks.yaml`
- Create: `kubernetes/apps/ai/buzz/app/kustomization.yaml`
- Create: `kubernetes/apps/ai/buzz/app/ocirepository.yaml`
- Create: `kubernetes/apps/ai/buzz/app/externalsecret.yaml`
- Create: `kubernetes/apps/ai/buzz/app/helmrelease.yaml`
- Create: `kubernetes/apps/ai/buzz/app/httproute.yaml`
- Modify: `kubernetes/apps/ai/kustomization.yaml` (add `./buzz/ks.yaml` to `resources`, alphabetical)

**Interfaces:**
- Consumes: Task 1's `GIT_PROBE`, `BUZZ_IMAGE_TAG`; Task 2's field names; the owner's 64-hex Nostr pubkey (`RELAY_OWNER_PUBKEY`, from the desktop app's profile → convert npub to hex with `nak decode` or the app's "copy hex"). It is public, so it goes in values, not the secret.
- Produces: Secret `buzz-secret`; HelmRelease `buzz` (release name `buzz` → chart fullname `buzz-relay` for Deployment/Service, per the chart's `contains "buzz" .Release.Name` rule; confirm in the render step); Service port 3000; host `buzz.${SECRET_DOMAIN}`.

- [ ] **Step 1: Write the render checks first** (they fail until the manifests exist). Save as a scratch script, not in the repo:

```bash
set -euo pipefail
kustomize build kubernetes/apps/ai/buzz/app >/dev/null           # kustomization valid
flux-local test --path kubernetes/apps/ai                        # Flux objects valid
r=$(helm template buzz oci://ghcr.io/block/buzz/charts/buzz --version 0.1.11 \
      -n ai -f <(yq '.spec.values' kubernetes/apps/ai/buzz/app/helmrelease.yaml))
grep -q 'kind: PodDisruptionBudget' <<<"$r" && { echo "FAIL: PDB rendered"; exit 1; }
grep -q 'kind: PersistentVolumeClaim' <<<"$r" && { echo "FAIL: PVC rendered"; exit 1; }
grep -q 'kind: Ingress' <<<"$r" && { echo "FAIL: Ingress rendered"; exit 1; }
grep -q 'kind: HTTPRoute' <<<"$r" && { echo "FAIL: chart HTTPRoute rendered"; exit 1; }
grep -q 'ghcr.io/home-operations/postgres-init' <<<"$r" || { echo "FAIL: no init"; exit 1; }
grep -q "image: ghcr.io/block/buzz:${BUZZ_IMAGE_TAG}" <<<"$r" || { echo "FAIL: image"; exit 1; }
grep -q 'name: buzz-secret' <<<"$r" || { echo "FAIL: existingSecret"; exit 1; }
grep -q 'kind: ServiceMonitor' <<<"$r" || { echo "FAIL: no ServiceMonitor"; exit 1; }
echo PASS
```

The Reloader annotation lives in a Flux `postRenderers` patch, so `helm template` won't show it. Check it separately: `yq '.spec.postRenderers[0].kustomize.patches[] | select(.target.kind=="Deployment")' kubernetes/apps/ai/buzz/app/helmrelease.yaml` is non-empty.

- [ ] **Step 2: Run the checks to verify they fail**

Expected: `kustomize build` error (path missing).

- [ ] **Step 3: Write `ks.yaml`** — Flux Kustomization `buzz`, `path: ./kubernetes/apps/ai/buzz/app`, `targetNamespace: ai`, `dependsOn` the three names in Global Constraints, `wait: true`, `interval: 30m`, `retryInterval: 1m`, `timeout: 10m` (first boot runs migrations and, if on, the probe), `postBuild.substitute: {APP: buzz, NS: ai}`. Pattern: `kubernetes/apps/productivity/n8n/ks.yaml` minus the volsync/kopiur keys (no PVC).

- [ ] **Step 4: Write `ocirepository.yaml`** — name `buzz`, `url: oci://ghcr.io/block/buzz/charts/buzz`, `ref.tag: 0.1.11`, the Helm `layerSelector` from `kubernetes/apps/identity/authentik/app/ocirepository.yaml`.

- [ ] **Step 5: Write `externalsecret.yaml`** — target `buzz-secret`, `dataFrom.extract` keys `buzz` and `cloudnative-pg`. Template `data` keys (all the chart reads, plus init):

| Key | Value |
| --- | --- |
| `BUZZ_RELAY_PRIVATE_KEY` | `{{ .Buzz__RelayPrivateKey }}` |
| `BUZZ_GIT_HOOK_HMAC_SECRET` | `{{ .Buzz__GitHookHmacSecret }}` |
| `DATABASE_URL` | `postgres://{{ .Buzz__Postgres__User }}:{{ .Buzz__Postgres__Password }}@${POSTGRES_HOST}:5432/{{ .Buzz__Postgres__DbName }}` |
| `REDIS_URL` | `redis://dragonfly.database.svc.cluster.local:6379` |
| `BUZZ_S3_ACCESS_KEY` / `BUZZ_S3_SECRET_KEY` | `{{ .Buzz__Garage__AccessKey }}` / `{{ .Buzz__Garage__SecretKey }}` |
| `INIT_POSTGRES_HOST` | `${POSTGRES_HOST}` |
| `INIT_POSTGRES_DBNAME` / `_USER` / `_PASS` | the three `Buzz__Postgres__*` fields |
| `INIT_POSTGRES_SUPER_PASS` | `{{ .Postgres__SuperPassword }}` |

Add the `externalsecret-refresh` component in `app/kustomization.yaml`, as n8n does.

- [ ] **Step 6: Write `helmrelease.yaml`** — `chartRef: {kind: OCIRepository, name: buzz}`, `interval: 1h`, `timeout: 10m`. Values (only these; everything else is chart default):

```yaml
image:
  tag: <BUZZ_IMAGE_TAG>
relayUrl: wss://buzz.${SECRET_DOMAIN}
ownerPubkey: <RELAY_OWNER_PUBKEY hex>
secrets:
  existingSecret: buzz-secret
relay:
  corsOrigins:
    - https://buzz.${SECRET_DOMAIN}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 1Gi}
  extraEnv:
    - name: BUZZ_GIT_CONFORMANCE_PROBE
      value: "<true|false from GIT_PROBE>"
extraInitContainers:
  - name: init-db
    image: ghcr.io/home-operations/postgres-init:rolling
    envFrom:
      - secretRef:
          name: buzz-secret
    securityContext: {runAsNonRoot: true, runAsUser: 65532, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits: {memory: 128Mi}
podDisruptionBudget:
  enabled: false
persistence:
  git:
    enabled: false        # emptyDir scratch; git state is in S3 + Postgres
    size: 5Gi
git:
  packCacheVolumeSize: 2Gi
  packCacheMaxBytes: 1610612736
s3:
  endpoint: ${SECRET_GARAGE_S3_ENDPOINT}
  bucket: buzz-media
  region: us-east-1
  addressingStyle: path
serviceMonitor:
  enabled: true
httproute:
  enabled: false
```

`postRenderers[0].kustomize.patches`: a strategic-merge patch, targeting `kind: Deployment, name: buzz-relay`, that adds `metadata.annotations: {secret.reloader.stakater.com/reload: buzz-secret}`. Copy the shape and the explanatory comment style from `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml`. Keep the `postgres-init` tag at `rolling`, matching every other app. Schema line: the `helm.toolkit.fluxcd.io` HelmRelease schema used by `kubernetes/apps/identity/authentik/app/helmrelease.yaml`.

- [ ] **Step 7: Write `httproute.yaml`** — name `buzz`, host `buzz.${SECRET_DOMAIN}`, parentRef `internal`/`network`/`https`, backend `buzz-relay:3000`. Annotations: `gatus.home-operations.com/endpoint: "group: ai"` and the `gethomepage.dev/*` set (name "Buzz", group "AI", icon `mdi-message-text`, description "Agent workspace relay"). Copy from `kubernetes/apps/ai/hermes/app/httproute.yaml`.

- [ ] **Step 8: Run the render checks from Step 1, then the repo hooks**

Run: the scratch script, then `lefthook run pre-commit`
Expected: `PASS`, the postRenderer query non-empty, hooks clean (yamlfmt, gitleaks).

- [ ] **Step 9: Commit**

```bash
git add kubernetes/apps/ai/buzz kubernetes/apps/ai/kustomization.yaml
git commit -m "buzz: self-hosted buzz relay in ai namespace"
```

---

### Task 4: Deploy, admit members, verify end to end

**Files:**
- Modify: `kubernetes/apps/ai/buzz/README.md` ("First deploy" and "Verify" sections)

**Interfaces:**
- Consumes: everything above. Produces a working relay at `wss://buzz.${SECRET_DOMAIN}` with the owner and at least one agent as members.

- [ ] **Step 1: Run Task 2's script for real,** then open the PR and merge it (pushing to `main` reconciles via webhook; do not `flux reconcile`).

- [ ] **Step 2: Verify reconcile and boot**

Run: `kubectl -n ai get ks buzz hr buzz; kubectl -n ai logs deploy/buzz-relay -c init-db; kubectl -n ai logs deploy/buzz-relay | grep -iE 'migrat|conformance|listening'`
Expected: Ready=True for both; init log shows `CREATE ROLE`/`CREATE DATABASE` (or "exists") and `ALTER ROLE`; relay logs show migrations applied, probe result matching `GIT_PROBE`, and the listen address.

- [ ] **Step 3: Verify NIP-11 and closed-relay auth from the LAN**

Run: `curl -s -H 'Accept: application/nostr+json' https://buzz.${SECRET_DOMAIN}/ | jq '{name,pubkey,supported_nips}'`
Expected: JSON with a 64-hex `pubkey` and `42` in `supported_nips`. Record which key `pubkey` is (relay key from `Buzz__RelayPrivateKey`, or the owner key); it should not change across restarts. From outside LAN and tailnet: the name does not resolve or connect.

- [ ] **Step 4: Admit members** (owner is implicit; add each agent's pubkey)

Run: `kubectl -n ai exec deploy/buzz-relay -- buzz-admin add-member --pubkey <agent npub|hex> --role member` then `… list-members`
Expected: the agent listed. Record each agent's key location (`secret/<agent>` field `<Agent>__Buzz__PrivateKey`) in the README. Keys are generated per agent with `buzz-admin generate-key` and stored in OpenBao, never in git.

- [ ] **Step 5: End-to-end check** — desktop app with `BUZZ_RELAY_URL=wss://buzz.${SECRET_DOMAIN}`: sign in as owner, create a channel, upload an image (media → Garage), post. Then `buzz-cli` with an agent key posts in the same channel.
Expected: both messages visible in the desktop app; image renders; `kubectl -n ai logs deploy/buzz-relay` shows no S3 or Redis errors; the desktop connection is still up after one hour (Review Focus 3).

- [ ] **Step 6: Verify rotation will restart the pod**

Run: `kubectl -n ai get deploy buzz-relay -o jsonpath='{.metadata.annotations.secret\.reloader\.stakater\.com/reload}'`
Expected: `buzz-secret`. (Adding an unused OpenBao field would not change the templated Secret, so it can't exercise Reloader. The first real rotation does: `bao kv patch secret/buzz Buzz__Postgres__Password=$(openssl rand -hex 32)`, then force-sync. Reloader rolls the pod and `postgres-init` resets the role password on start.)

- [ ] **Step 7: Verify drain is not blocked**

Run: `kubectl get pdb -n ai | grep buzz || echo none`
Expected: `none`.

- [ ] **Step 8: Commit** the README's "First deploy" (script, Garage bucket/key, owner pubkey source, `add-member`) and "Verify" (Steps 2, 3 and 5 commands).

```bash
git add kubernetes/apps/ai/buzz/README.md
git commit -m "buzz: first-deploy and verification runbook"
```

---

## Out of scope (follow-up plans)

- Connecting `ai/hermes` to the relay (`gateway.platforms.buzz`: `BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY` from OpenBao, `BUZZ_ALLOWED_USERS`, `require_mention: true`). Its own small PR, because it changes Hermes' attack surface.
- Public exposure via `external-pangolin`: blocked on upstream rate limiting.
- Moving history from the hosted `communities.buzz.xyz` community: no export tool documented.
- Backups: Postgres is covered by CNPG/Barman and media by Garage's own durability; nothing else is stateful. If Garage-side replication of `buzz-media` is wanted, that's a Garage task.
