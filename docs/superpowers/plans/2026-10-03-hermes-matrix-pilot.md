# Hermes on Matrix — Bosun pilot: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put Bosun on Matrix with E2EE on the derekjacobs.dev homeserver. Prove with a throwaway `canary` profile that a *named* Hermes profile gets its own Matrix identity and OpenBao-sourced secrets inside the one `ai/hermes` multiplexer. Then write the pattern down for Fizz, Pollen, Honey and Wasp.

**Architecture:**
- Git changes (PR 1):
  - Force Hermes multiplexing on with an env flag.
  - Add Bosun's `MATRIX_*` to the existing `hermes-secret` ExternalSecret.
  - Add a per-profile ExternalSecret that renders one `profile.env`. It is mounted read-only as a directory at `/run/hermes-profiles/canary/`.
- Everything else is live, ordered steps:
  - MAS accounts and compatibility tokens.
  - OpenBao writes.
  - Profile creation and config, run in the pod as the gateway user.
  - The P0–P6 checks.
  - Cleanup (PR 2), which removes canary and adds the README pattern.

**Tech Stack:**
- Hermes Agent v0.21.4 (`docker.io/nousresearch/hermes-agent:v2026.9.21`, app-template).
- External Secrets (OpenBao `ClusterSecretStore`, `engineVersion: v2`).
- MAS 1.26 `mas-cli`, Synapse 1.162 (ESS `matrix-stack`).
- LiteLLM (`ai/litellm:4000`).
- Reloader.

**Spec:** `docs/superpowers/specs/2026-10-03-hermes-matrix-pilot-design.md`. Read it first; every "why" lives there.

> **Execution notes, 2026-10-04.** These amend the tasks below, and these notes win where they differ.
>
> **The named-profile subject is Wasp, not `canary`.** Bosun had already onboarded Wasp into the multiplexer (#2057) using this exact pattern, so Derek chose to test P3–P6 on that real agent.
> - Wasp is `@wasp:derekjacobs.dev`, device `WASPHERMES`.
> - Its fields are `Wasp__Matrix__AccessToken` / `Wasp__Matrix__RecoveryKey` in `secret/hermes-wasp`, following Wasp's own naming.
> - Its recovery key goes to `/opt/data/profiles/wasp/matrix-recovery-key.txt`.
> - P4's LiteLLM spend check becomes "Wasp answers with its own provider credential".
> - `canary` never ran. Its manifests were removed in #2064, and its MAS user, OpenBao key and LiteLLM key are retired live.
> - Read `canary` below as `wasp`.
>
> **Federation needed three extra PRs:**
> - **#2059** pins `matrix.*` to the Pangolin VPS with `hostAliases`, instead of an SSRF allowlist.
> - **#2059** also adds a CoreDNS `bluevulpine.net.` block forwarding to public DNS.
> - **#2062** sets `ndots:1` on Synapse, because CoreDNS `autopath` otherwise bypasses that block.
>
> **Tooling corrections:**
> - The privilege-drop helper is `/command/s6-setuidgid`; it isn't on the `kubectl exec` PATH.
> - Generated credentials are piped into OpenBao by the agent, never handed to Derek.

## Global Constraints

- Behaviour claims come from **pod source** (`/opt/hermes`, v0.21.4), never from `~/.hermes/hermes-agent` (a newer, different build).
- Multiplexing is **explicit**: `GATEWAY_MULTIPLEX_PROFILES: "true"` in the HelmRelease env. The implicit default refuses on s6, and PID 1 is `s6-svscan`.
- Matrix users and devices:
  - `@bosun:derekjacobs.dev` with device `BOSUNHERMES`.
  - `@canary:derekjacobs.dev` with device `CANARYHERMES`.
  - Alphanumeric device IDs. **Never** `--yes-i-want-to-grant-synapse-admin-privileges`.
- OpenBao keys:
  - `secret/hermes`: add `Hermes__Matrix__AccessToken` and `Hermes__Matrix__RecoveryKey`.
  - `secret/hermes-canary`: `Hermes__Matrix__AccessToken`, `Hermes__Matrix__RecoveryKey`, `Hermes__OpenaiApiKey`.
- These values travel via the **secret path**, never YAML-only:
  - `MATRIX_HOMESERVER=https://matrix.derekjacobs.dev`
  - `MATRIX_E2EE_MODE=required`
  - `MATRIX_ACCESS_TOKEN`
  - `MATRIX_RECOVERY_KEY`
  - `MATRIX_RECOVERY_KEY_OUTPUT_FILE`
  
  The YAML `homeserver` is blanked by the env pass (`config_env.py:547`).
- These go in the profile's `config.yaml` under `platforms.matrix`:
  - `device_id`
  - `allowed_users: "@bluevulpine:bluevulpine.net"`
- Recovery-key output paths are **distinct per profile** and must not pre-exist (`O_EXCL`):
  - Bosun: `/opt/data/matrix-recovery-key.txt`
  - canary: `/opt/data/profiles/canary/matrix-recovery-key.txt`
- canary's secret mount:
  - Secret `hermes-profile-canary`, single key `profile.env`.
  - Mounted as a **directory** (no `subPath`) at `/run/hermes-profiles/canary`, `readOnly`, `defaultMode: 0440`.
- canary's `secrets.command`: `{enabled: true, command: "/bin/cat /run/hermes-profiles/canary/profile.env", override_existing: true}`.
- canary's model: `provider: openai-api`, `base_url: http://litellm.ai.svc.cluster.local:4000/v1`, `default: spark-gpt-oss-20b`. Key `OPENAI_API_KEY` is a LiteLLM virtual key. Local model, $0.
- Every `hermes` CLI step in the pod runs as `s6-setuidgid hermes hermes …`. `kubectl exec` is root, and the CLI does not drop privileges.
- `/opt/data/.env` must never gain `MATRIX_*` keys, because `.env` beats process env in the launch scope. Check **names only**; never print values.
- **The agent never prints, reads into its context, or writes a token.** Derek runs every step that materialises a credential (token issue, `bao kv patch`, LiteLLM key, reading the recovery key). The agent runs read-only verification. It may run `mas-cli manage register-user` and the in-pod profile/config steps **only** after Derek approves each one.
- Commits: Scoped Commits, authored `fizz-bot-bvn[bot] <324971095+fizz-bot-bvn[bot]@users.noreply.github.com>` via per-command `git -c`, with `Co-Authored-By` and `Claude-Session` trailers. Never `git config`. Push and PR only when Derek asks. Derek merges, via ask-rule prompts.
- Pushing to `main` auto-reconciles. **Never** run `flux reconcile` after a push.
- Never `lefthook run pre-commit --all-files`; staged only.

## Review Focus

1. **A credential file arriving after canary is first loaded.** If `profile.env` is missing or empty at first load, canary is skipped and never retried (the rescan signature excludes the mount). Expected: Task 6 refuses to create canary until the file's key *names* are present. The fallback is touching `config.yaml`.
2. **A root-owned profile tree.** A profile created by a root `kubectl exec` breaks E2EE store creation. Expected: Task 6 checks that every path under `/opt/data/profiles/canary` is owned by uid 10000.
3. **An ExternalSecret that references an OpenBao field that doesn't exist yet**, such as the recovery key before first boot. With `engineVersion: v2` that fails the sync and blocks the pod. Expected: Task 3 seeds every referenced field, empty for the recovery keys, before merge. Task 4 checks `SecretSynced` before anything else.
4. **Rotating one agent restarts all of them** (Reloader + `Recreate`). Expected: P6 records Bosun's reconnect as well as canary's, and the README states the fleet-wide restart.
5. **A hot-added canary inheriting Bosun's Anthropic model block.** Expected: Task 6 writes the `model:` block in the same step that creates the profile, and P4 checks LiteLLM spend against canary's key.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `kubernetes/apps/ai/hermes/app/helmrelease.yaml` | modify | `GATEWAY_MULTIPLEX_PROFILES` env; `canary-secrets` persistence (secret dir mount) |
| `kubernetes/apps/ai/hermes/app/externalsecret.yaml` | modify | Bosun's five `MATRIX_*` in `hermes-secret` |
| `kubernetes/apps/ai/hermes/app/externalsecret-profile-canary.yaml` | create (removed in Task 8) | `hermes-profile-canary` → `profile.env` |
| `kubernetes/apps/ai/hermes/app/kustomization.yaml` | modify | list the new ExternalSecret |
| `kubernetes/apps/ai/hermes/README.md` | modify (Task 8) | "Matrix" and "Adding an agent profile" sections |
| `.superpowers/sdd/2026-10-03-hermes-matrix-pilot/` | create, git-ignored | `render.sh`, `check-pr1.sh`, `check-live.sh`, ledger |

---

### Task 1: Render-check harness (RED)

**Files:**
- Create: `.superpowers/sdd/2026-10-03-hermes-matrix-pilot/render.sh`
- Create: `.superpowers/sdd/2026-10-03-hermes-matrix-pilot/check-pr1.sh`

**Interfaces:**
- Produces: `render` (bash function: renders `kubernetes/apps/ai/hermes/app` with the Kustomization's own `postBuild.substitute`) and `check-pr1.sh` (exit 0 = every PR-1 assertion passes).

- [ ] **Step 1: Write `render.sh`.** It reads the substitutions from `ks.yaml` itself, so it can't drift.

```bash
#!/bin/bash
# render: build the hermes app the way Flux does, using ks.yaml's own postBuild.substitute.
render() {
  local root; root="$(git rev-parse --show-toplevel)"
  # A while-read loop, not mapfile: scripts run under macOS /bin/bash 3.2, which has no mapfile.
  local -a subs=()
  local line
  while IFS= read -r line; do subs+=("$line"); done < <(
    # explode(.) first: ks.yaml sets APP: *app (a YAML alias), which yq would otherwise print literally.
    yq -r 'explode(.) | .spec.postBuild.substitute | to_entries | .[] | "\(.key)=\(.value)"' \
      "$root/kubernetes/apps/ai/hermes/ks.yaml")
  kustomize build "$root/kubernetes/apps/ai/hermes/app" | env \
    SECRET_DOMAIN=derekjacobs.dev SECRET_DOMAIN_BLOG=bluevulpine.net TIMEZONE=America/Chicago \
    "${subs[@]}" flux envsubst --strict
}
```

- [ ] **Step 2: Write `check-pr1.sh`**

```bash
#!/bin/bash
# PR-1 assertions for the hermes Matrix pilot. Exit 0 only if all pass.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
. .superpowers/sdd/2026-10-03-hermes-matrix-pilot/render.sh
out="$(render)" || { echo "FAIL render"; exit 1; }
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
ctr='select(.kind=="HelmRelease") | .spec.values.controllers.hermes.containers.app'
per='select(.kind=="HelmRelease") | .spec.values.persistence'
es='select(.kind=="ExternalSecret" and .metadata.name=="hermes-secret") | .spec.target.template.data'
pe='select(.kind=="ExternalSecret" and .metadata.name=="hermes-profile-canary")'

check multiplex-env "$(echo "$out" | yq "$ctr | .env.GATEWAY_MULTIPLEX_PROFILES")" "true"
check bosun-homeserver "$(echo "$out" | yq "$es | .MATRIX_HOMESERVER")" "https://matrix.derekjacobs.dev"
check bosun-e2ee "$(echo "$out" | yq "$es | .MATRIX_E2EE_MODE")" "required"
check bosun-token "$(echo "$out" | yq "$es | .MATRIX_ACCESS_TOKEN")" "{{ .Hermes__Matrix__AccessToken }}"
check bosun-recovery "$(echo "$out" | yq "$es | .MATRIX_RECOVERY_KEY")" "{{ .Hermes__Matrix__RecoveryKey }}"
check bosun-recovery-out "$(echo "$out" | yq "$es | .MATRIX_RECOVERY_KEY_OUTPUT_FILE")" "/opt/data/matrix-recovery-key.txt"
check bosun-existing-kept "$(echo "$out" | yq "$es | .API_SERVER_KEY")" "{{ .Hermes__ApiServerKey }}"
check canary-es-key "$(echo "$out" | yq "$pe | .spec.dataFrom[0].extract.key")" "hermes-canary"
check canary-es-onekey "$(echo "$out" | yq "$pe | .spec.target.template.data | keys | join(\",\")")" "profile.env"
pf="$(echo "$out" | yq "$pe | .spec.target.template.data[\"profile.env\"]")"
for k in MATRIX_HOMESERVER MATRIX_E2EE_MODE MATRIX_ACCESS_TOKEN MATRIX_RECOVERY_KEY MATRIX_RECOVERY_KEY_OUTPUT_FILE OPENAI_API_KEY OPENAI_BASE_URL; do
  check "canary-env-$k" "$(echo "$pf" | grep -c "^$k=")" "1"
done
check canary-env-homeserver-val "$(echo "$pf" | grep '^MATRIX_HOMESERVER=' | cut -d= -f2-)" "https://matrix.derekjacobs.dev"
check canary-env-outfile-val "$(echo "$pf" | grep '^MATRIX_RECOVERY_KEY_OUTPUT_FILE=' | cut -d= -f2-)" "/opt/data/profiles/canary/matrix-recovery-key.txt"
# Bracket syntax: in yq, ".canary-secrets" parses as ".canary minus secrets".
cs="$per | .[\"canary-secrets\"]"
check canary-mount-type "$(echo "$out" | yq "$cs | .type")" "secret"
check canary-mount-name "$(echo "$out" | yq "$cs | .name")" "hermes-profile-canary"
check canary-mount-mode "$(echo "$out" | yq "$cs | .defaultMode")" "288"
check canary-mount-path "$(echo "$out" | yq "$cs | .globalMounts[0].path")" "/run/hermes-profiles/canary"
check canary-mount-ro "$(echo "$out" | yq "$cs | .globalMounts[0].readOnly")" "true"
check canary-mount-nosubpath "$(echo "$out" | yq "$cs | .globalMounts[0].subPath")" "null"
check no-secret-values "$(echo "$out" | grep -c -E 'mct_|syt_|sk-[A-Za-z0-9]{8}')" "0"
exit $fail
```

`288` is `0440` octal (`0o440 == 288`). yq prints the decimal value of a YAML octal.

- [ ] **Step 3: Run it and watch it fail**

Run: `/bin/bash .superpowers/sdd/2026-10-03-hermes-matrix-pilot/check-pr1.sh`
Expected: `FAIL multiplex-env` and the other new checks FAIL; `PASS bosun-existing-kept`; exit 1.

- [ ] **Step 4: Ledger.** Create `progress.md` with first line `# SDD ledger — plan: docs/superpowers/plans/2026-10-03-hermes-matrix-pilot.md`. There is no commit for this task: the workspace is git-ignored.

---

### Task 2: PR 1 manifests (GREEN)

**Files:**
- Modify: `kubernetes/apps/ai/hermes/app/helmrelease.yaml` (container `env`; `persistence`)
- Modify: `kubernetes/apps/ai/hermes/app/externalsecret.yaml`
- Create: `kubernetes/apps/ai/hermes/app/externalsecret-profile-canary.yaml`
- Modify: `kubernetes/apps/ai/hermes/app/kustomization.yaml`

**Interfaces:**
- Consumes: Task 1's `check-pr1.sh`.
- Produces: Secret `hermes-secret` with `MATRIX_*`; Secret `hermes-profile-canary` with key `profile.env`; a pod mount at `/run/hermes-profiles/canary/profile.env`; process env `GATEWAY_MULTIPLEX_PROFILES=true`.

- [ ] **Step 1: HelmRelease env.** In `controllers.hermes.containers.app.env`, after `API_SERVER_PORT: "8642"`:

```yaml
              # Serve every profile under /opt/data/profiles from this one gateway
              # (one Hermes per agent profile, not one pod per agent; see
              # docs/superpowers/specs/2026-10-03-hermes-matrix-pilot-design.md).
              # MUST be explicit: v0.21.4's implicit default refuses on s6-supervised
              # containers (_host_supports_migration), and PID 1 here is s6-svscan,
              # so without this a second profile would run as a second gateway
              # process. An explicit true logs nothing at boot; check
              # /opt/data/gateway_state.json served_profiles instead.
              GATEWAY_MULTIPLEX_PROFILES: "true"
```

- [ ] **Step 2: HelmRelease persistence.** After the `tmp:` entry under `persistence:`:

```yaml
      # canary's credentials (throwaway pilot profile; removed after the pilot).
      # A named profile cannot read process env under multiplexing, so its
      # secrets arrive as one KEY=VALUE file read by the profile's own
      # secrets.command source. Directory mount, NOT subPath: a subPath mount
      # never receives Secret updates. 0440 + fsGroup 10000 is exactly what
      # the gateway (uid/gid 10000, no caps) needs to read it.
      canary-secrets:
        type: secret
        name: hermes-profile-canary
        defaultMode: 0440
        globalMounts:
          - path: /run/hermes-profiles/canary
            readOnly: true
```

- [ ] **Step 3: Bosun's `MATRIX_*`.** In `externalsecret.yaml`, under `template.data`, after `API_SERVER_KEY`:

```yaml
        # Bosun on Matrix (@bosun:derekjacobs.dev, device BOSUNHERMES). These
        # MUST arrive via env/scope, not config.yaml: the adapter's credential
        # pass always rewrites extra.homeserver from MATRIX_HOMESERVER, so a
        # YAML-only homeserver is blanked. Never add MATRIX_* to /opt/data/.env:
        # it beats process env in the launch scope and would shadow OpenBao.
        MATRIX_HOMESERVER: "https://matrix.${SECRET_DOMAIN}"
        MATRIX_E2EE_MODE: required
        MATRIX_ACCESS_TOKEN: "{{ .Hermes__Matrix__AccessToken }}"
        # Empty until the first boot writes the bootstrapped key to the file
        # below; Derek then moves it here. Empty is treated as unset.
        MATRIX_RECOVERY_KEY: "{{ .Hermes__Matrix__RecoveryKey }}"
        MATRIX_RECOVERY_KEY_OUTPUT_FILE: /opt/data/matrix-recovery-key.txt
```

- [ ] **Step 4: Create `externalsecret-profile-canary.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
# THROWAWAY: the canary profile of the Hermes-on-Matrix pilot. Removed with the
# profile once the pilot passes (plan Task 8).
#
# One file, profile.env, holding KEY=VALUE lines. Mounted read-only at
# /run/hermes-profiles/canary/ and read by the profile's own config.yaml:
#   secrets.command: {enabled: true, override_existing: true,
#     command: "/bin/cat /run/hermes-profiles/canary/profile.env"}
# A named profile cannot borrow process env under multiplexing, which is why
# this is a file and not more envFrom.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: &name hermes-profile-canary
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: *name
    template:
      engineVersion: v2
      data:
        profile.env: |
          MATRIX_HOMESERVER=https://matrix.${SECRET_DOMAIN}
          MATRIX_E2EE_MODE=required
          MATRIX_ACCESS_TOKEN={{ .Hermes__Matrix__AccessToken }}
          MATRIX_RECOVERY_KEY={{ .Hermes__Matrix__RecoveryKey }}
          MATRIX_RECOVERY_KEY_OUTPUT_FILE=/opt/data/profiles/canary/matrix-recovery-key.txt
          OPENAI_API_KEY={{ .Hermes__OpenaiApiKey }}
          OPENAI_BASE_URL=http://litellm.ai.svc.cluster.local:4000/v1
  dataFrom:
    - extract:
        key: hermes-canary
```

- [ ] **Step 5: kustomization.** Add `- ./externalsecret-profile-canary.yaml` after `- ./externalsecret.yaml` in `resources`.

- [ ] **Step 6: Run the check (GREEN)**

Run: `/bin/bash .superpowers/sdd/2026-10-03-hermes-matrix-pilot/check-pr1.sh`
Expected: every line PASS, exit 0.

- [ ] **Step 7: Validate**

```bash
git add kubernetes/apps/ai/hermes/app/
lefthook run pre-commit
flux-local test -A --path kubernetes/flux/cluster > .superpowers/sdd/2026-10-03-hermes-matrix-pilot/flux-local.log 2>&1; tail -2 .superpowers/sdd/2026-10-03-hermes-matrix-pilot/flux-local.log
```

Expected: yamlfmt and gitleaks ✔; flux-local `N passed`, 0 failed, including `hermes`. If yamlfmt rewrites a file, re-stage and re-run the check.

- [ ] **Step 8: Commit** (fizz-bot, via the commit helper pattern from the previous plan)

Subject: `hermes: matrix identity for bosun, per-profile secret mount for a canary profile`. The body states why multiplexing is explicit and why the secret is a file.

---

### Task 3: Prerequisites (Derek; agent verifies read-only)

**Files:** none.

**Interfaces:**
- Produces: MAS users `bosun` and `canary`; OpenBao fields that every ExternalSecret template reference needs; a LiteLLM virtual key.

- [ ] **Step 1: MAS users** (the agent may run these after Derek approves; they create no credentials):

```bash
kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- mas-cli manage register-user -y -d Bosun bosun
kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- mas-cli manage register-user -y -d Canary canary
```

Expected: each reports the user was created. Neither command is given `--admin`.

- [ ] **Step 2: Tokens into OpenBao (Derek only).** MAS compatibility tokens start with `mct_`. The token goes straight into OpenBao and is never echoed:

```bash
MAS=(kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- mas-cli manage)
T=$("${MAS[@]}" issue-compatibility-token bosun BOSUNHERMES 2>&1 | grep -o 'mct_[A-Za-z0-9_]*' | head -1)
[ -n "$T" ] && bao kv patch secret/hermes Hermes__Matrix__AccessToken="$T" Hermes__Matrix__RecoveryKey= ; unset T
T=$("${MAS[@]}" issue-compatibility-token canary CANARYHERMES 2>&1 | grep -o 'mct_[A-Za-z0-9_]*' | head -1)
[ -n "$T" ] && bao kv put secret/hermes-canary Hermes__Matrix__AccessToken="$T" Hermes__Matrix__RecoveryKey= Hermes__OpenaiApiKey=PENDING ; unset T
```

If either `[ -n "$T" ]` guard fails (the output format differs), stop. Run the issue command once by hand to see the format, then copy the token into `bao` with `read -s`. **Never paste it into chat.**

- [ ] **Step 3: LiteLLM virtual key (Derek).**
  - In the LiteLLM UI, create the key: alias `hermes-canary`, models `[spark-gpt-oss-20b]`, a small max budget.
  - Then run `bao kv patch secret/hermes-canary Hermes__OpenaiApiKey='…'`.

- [ ] **Step 4: Verify (agent, read-only).** Key names only:

```bash
bao kv get -format=json secret/hermes | jq -r '.data.data | keys[] | select(startswith("Hermes__Matrix"))'
bao kv get -format=json secret/hermes-canary | jq -r '.data.data | keys[]'
```

Expected:
- the first lists `Hermes__Matrix__AccessToken` and `Hermes__Matrix__RecoveryKey`
- the second lists those two plus `Hermes__OpenaiApiKey`

If `bao kv get` is refused to the agent, Derek runs the two commands and pastes the **key names** only.

- [ ] **Step 5: Token lifetime baseline.** Record the issue time in the ledger. Task 9 re-checks `whoami` after 25h.

---

### Task 4: Push PR 1, merge (Derek), P0

**Files:** none.

- [ ] **Step 1:** Push the branch and open a draft PR as fizz-bot **only when Derek asks**. The PR body links the spec and lists Task 3 as a merge precondition. Derek merges.

- [ ] **Step 2: Secrets synced before anything else**

```bash
kubectl -n ai get externalsecret hermes-secret hermes-profile-canary -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].reason
```

Expected: both `SecretSynced`. If one is not, the cause is a missing OpenBao field (Review Focus 3). Fix that before going on.

- [ ] **Step 3: Pod rolled** (Reloader and the HelmRelease change both trigger it): `kubectl -n ai rollout status deploy/hermes --timeout=15m`.

- [ ] **Step 4: Write `check-live.sh`.** Read-only, names and states only:

```bash
#!/bin/bash
# Read-only live checks for the hermes Matrix pilot. Never prints a value.
kubectl -n ai exec deploy/hermes -- sh -c '
  echo "== gateway_state"; python3 -c "import json;d=json.load(open(\"/opt/data/gateway_state.json\"));print(\"served=\",d.get(\"served_profiles\"),\"| standalone_reason=\",d.get(\"multiplex_standalone_reason\"))"
  echo "== gateway processes"; pgrep -fc "hermes.*gateway run" || true
  echo "== .env MATRIX keys (count)"; grep -c "^MATRIX_" /opt/data/.env || true
  echo "== canary mount key names"; [ -f /run/hermes-profiles/canary/profile.env ] && cut -d= -f1 /run/hermes-profiles/canary/profile.env | tr "\n" " "; echo
  echo "== canary tree owners (non-10000)"; [ -d /opt/data/profiles/canary ] && find /opt/data/profiles/canary ! -uid 10000 | head -5
'
echo "== recent multiplex / matrix log lines"
kubectl -n ai logs deploy/hermes --since=30m | grep -E "MULTIPLEX|Single-profile|stays standalone|matrix|Matrix" | grep -v -i -E "token=|mct_" | tail -20
```

- [ ] **Step 5: P0.** Run: `/bin/bash .superpowers/sdd/2026-10-03-hermes-matrix-pilot/check-live.sh`

Expected:
- `served= ['default'] | standalone_reason= None`
- 1 gateway process
- `.env MATRIX keys` 0
- the canary mount shows exactly `MATRIX_HOMESERVER MATRIX_E2EE_MODE MATRIX_ACCESS_TOKEN MATRIX_RECOVERY_KEY MATRIX_RECOVERY_KEY_OUTPUT_FILE OPENAI_API_KEY OPENAI_BASE_URL`
- no "Single-profile install" and no "stays standalone" line since the roll

---

### Task 5: Bosun on Matrix — P1, P2

**Files:** none (live config on the PVC).

- [ ] **Step 1: Bosun's non-secret Matrix config.** Derek approves; the agent runs it as the gateway user. `hermes config set` keeps the file's comments.

```bash
H=(kubectl -n ai exec deploy/hermes -- s6-setuidgid hermes hermes)
"${H[@]}" config set platforms.matrix.device_id BOSUNHERMES
"${H[@]}" config set platforms.matrix.allowed_users "@bluevulpine:bluevulpine.net"
```

Expected: both report that the value is set. `grep -c '^MATRIX_' /opt/data/.env` is still 0. The `config set` must not have written to `.env`; if it did, stop and remove those keys.

- [ ] **Step 2: Restart to load it.** `kubectl -n ai rollout restart deploy/hermes && kubectl -n ai rollout status deploy/hermes --timeout=15m`. Bosun is briefly offline.

- [ ] **Step 3: Adapter up.** Run `check-live.sh`.

Expected log lines:
- Matrix connected as `@bosun:derekjacobs.dev`, device `BOSUNHERMES`, E2EE required
- the cross-signing bootstrap ran

None of these may appear: "homeserver URL not configured", "MATRIX_HOMESERVER is missing", a device-mismatch error.

- [ ] **Step 4: P2, recovery key into OpenBao (Derek).**

```bash
kubectl -n ai exec deploy/hermes -- cat /opt/data/matrix-recovery-key.txt | tr -d '\n' | { read -r K; bao kv patch secret/hermes Hermes__Matrix__RecoveryKey="$K"; unset K; }
kubectl -n ai exec deploy/hermes -- rm /opt/data/matrix-recovery-key.txt
kubectl -n ai annotate externalsecret hermes-secret force-sync="$(date +%s)" --overwrite
```

Reloader then rolls the pod. Expected after the roll: the log shows cross-signing verified via the recovery key and no new bootstrap. In Element, Bosun's device is verified by its owner.

- [ ] **Step 5: P1 (Derek).**
  - From `@bluevulpine:bluevulpine.net` in Element, start a DM to `@bosun:derekjacobs.dev`. Encryption is on by default; leave it on.
  - Send "ping". Expected: Bosun replies, and the reply decrypts with no "unable to decrypt".
  - The agent watches the logs for an E2EE-decrypted inbound message from `@bluevulpine:bluevulpine.net` and an outbound reply.

- [ ] **Step 6: Ledger.** Record P0, P1 and P2 with timestamps.

---

### Task 6: canary hot-add — P3, P4, P5 (add half)

**Files:** none (live).

- [ ] **Step 1: Precondition.** `check-live.sh` shows the canary mount with all 7 key names (Review Focus 1). Otherwise stop.

- [ ] **Step 2: Create and configure in one go, as the gateway user** (Derek approves). `profile create` nudges the multiplexer straight away, so canary is first loaded **before** the `config set` lines run: it has no credential yet and Bosun's seeded model. That is harmless. It is skipped, and each `config set` changes `config.yaml`, which changes its rescan signature, so the finished config is loaded on the next pass. A home with no `secrets:` block is never latched, so the command source still runs once it is configured.

```bash
H=(kubectl -n ai exec deploy/hermes -- s6-setuidgid hermes hermes)
"${H[@]}" profile create canary
"${H[@]}" -p canary config set model.provider openai-api
"${H[@]}" -p canary config set model.base_url http://litellm.ai.svc.cluster.local:4000/v1
"${H[@]}" -p canary config set model.default spark-gpt-oss-20b
"${H[@]}" -p canary config set model.api_mode chat_completions
"${H[@]}" -p canary config set secrets.command.enabled true
"${H[@]}" -p canary config set secrets.command.command "/bin/cat /run/hermes-profiles/canary/profile.env"
"${H[@]}" -p canary config set secrets.command.override_existing true
"${H[@]}" -p canary config set platforms.matrix.device_id CANARYHERMES
"${H[@]}" -p canary config set platforms.matrix.allowed_users "@bluevulpine:bluevulpine.net"
```

Expected: the profile is created without `--clone`. `hermes -p canary config show` (if the agent shows it, model and secrets sections only) has the values above and **no** `anthropic` provider. If `config set` rejects `model.api_mode`, drop that line and record a ruling.

- [ ] **Step 3: Ownership.** `check-live.sh` → "canary tree owners (non-10000)" prints nothing (Review Focus 2). If anything prints: `kubectl -n ai exec deploy/hermes -- chown -R 10000:10000 /opt/data/profiles/canary`, then re-check.

- [ ] **Step 4: P3 and P5 (add).** Within 60s, with no restart, the log shows `[MULTIPLEX] Now serving profile 'canary' (N adapter(s) connected; …)`. `check-live.sh` shows `served= ['default', 'canary']` and 1 gateway process. The log shows Matrix connected as `@canary:derekjacobs.dev` device `CANARYHERMES`, and no `duplicate_credential`. Bosun's Matrix adapter logs no disconnect.
  - If canary comes up adapter-less: `kubectl -n ai exec deploy/hermes -- s6-setuidgid hermes touch /opt/data/profiles/canary/config.yaml` and wait 30s.

- [ ] **Step 5: canary recovery key (Derek).** Same as Task 5 Step 4, with `/opt/data/profiles/canary/matrix-recovery-key.txt` → `secret/hermes-canary`, then force-sync `hermes-profile-canary`. This is required before P6. Afterwards the pod rolls: confirm both adapters reconnect.

- [ ] **Step 6: P4 (Derek sends, agent checks).**
  - **Allowed sender:** an encrypted DM from `@bluevulpine:bluevulpine.net` to `@canary` gets a reply.
  - **Spend:** LiteLLM's spend log (UI → Logs, filter key alias `hermes-canary`) shows the turn. Bosun's Anthropic usage does not change for it.
  - **Non-allowed sender:** a DM to `@canary` from an account not on the list (e.g. `@bluevulpine:derekjacobs.dev`) gets no turn; it is ignored or gets a pairing prompt.
  - **Isolation:** neither profile's log shows the other's user ID on its adapter.

- [ ] **Step 7: Ledger.** Record P3, P4 and P5 (add).

---

### Task 7: Rotation — P6

**Files:** none (live).

- [ ] **Step 1: Precondition.** `secret/hermes-canary` `Hermes__Matrix__RecoveryKey` is non-empty. Derek confirms by key length only: `bao kv get -field=Hermes__Matrix__RecoveryKey secret/hermes-canary | wc -c` > 1.

- [ ] **Step 2: Rotate (Derek):**

```bash
MAS=(kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- mas-cli manage)
"${MAS[@]}" kill-sessions canary
T=$("${MAS[@]}" issue-compatibility-token canary CANARYHERMES 2>&1 | grep -o 'mct_[A-Za-z0-9_]*' | head -1)
[ -n "$T" ] && bao kv patch secret/hermes-canary Hermes__Matrix__AccessToken="$T"; unset T
kubectl -n ai annotate externalsecret hermes-profile-canary force-sync="$(date +%s)" --overwrite
```

The order matters: `kill-sessions` revokes **every** session for the user, so it must come before the new token is issued. The device ID stays the **same**; a new device ID would reset the crypto store.

- [ ] **Step 3: Volume-only Secret → Reloader** (not settled by the review): `kubectl -n kube-system logs deploy/reloader --since=5m | grep -i hermes` shows a reload for `hermes-profile-canary`, and the pod rolls. If it doesn't: record a ruling, roll by hand (`kubectl -n ai rollout restart deploy/hermes`), and add a `secret.reloader.stakater.com/reload: hermes-profile-canary` annotation to the plan's follow-ups.

- [ ] **Step 4: P6.**
  - canary reconnects as `@canary` on `CANARYHERMES`, with no crypto-store reset in the log.
  - Element shows canary's device verified by its owner, with no new device.
  - **Bosun also reconnects.** Record its outage window: this is the fleet-wide restart that rotating any agent causes.
  - A new DM to canary decrypts and gets a reply.

- [ ] **Step 5: Ledger.**

---

### Task 8: Cleanup + README pattern (PR 2) — P5 (remove half)

**Files:**
- Delete: `kubernetes/apps/ai/hermes/app/externalsecret-profile-canary.yaml`
- Modify: `kubernetes/apps/ai/hermes/app/kustomization.yaml` (drop that resource)
- Modify: `kubernetes/apps/ai/hermes/app/helmrelease.yaml` (drop `canary-secrets`)
- Modify: `kubernetes/apps/ai/hermes/README.md` (add "Matrix" and "Adding an agent profile")

- [ ] **Step 1: P5 (remove), live, Derek approves:** `kubectl -n ai exec deploy/hermes -- s6-setuidgid hermes hermes profile delete canary`. Expected:
  - log: `[MULTIPLEX] Profile 'canary' deleted — N adapter(s) stopped and unrouted`
  - `served= ['default']`
  - Bosun's Matrix connection is not interrupted

- [ ] **Step 2: Retire the identity (Derek):** `mas-cli manage kill-sessions canary`, `mas-cli manage lock-user canary`, `bao kv delete secret/hermes-canary`, and revoke the `hermes-canary` LiteLLM key.

- [ ] **Step 3: Extend `check-pr1.sh` into `check-pr2.sh`** (RED first):
  - assert `hermes-profile-canary` is **absent** and `canary-secrets` is `null`
  - assert every Bosun `MATRIX_*` and `GATEWAY_MULTIPLEX_PROFILES` check still passes
  - assert README contains the headings `## Matrix` and `## Adding an agent profile`

  Run it; expect FAIL on the absence and README checks.

- [ ] **Step 4: Remove canary from git** (the three manifest edits above).

- [ ] **Step 5: README.** Add `## Matrix` (Bosun's identity, where each setting lives and why, recovery-key handling, the fleet-wide restart on rotation). Then add `## Adding an agent profile` as a numbered recipe, generalised from Tasks 3–7 with `<agent>` in place of `canary`:
  - the identity commands
  - OpenBao `secret/hermes-<agent>` fields
  - an ExternalSecret `hermes-profile-<agent>` rendering `profile.env`
  - persistence `<agent>-secrets` → `/run/hermes-profiles/<agent>` 0440
  - the in-pod `profile create` + `config set` block run with `s6-setuidgid hermes`
  - the model block (LiteLLM or the agent's own provider)
  - the precondition, ownership, P3/P4 checks, recovery-key step and rotation order

  Name the traps that cost real time here: YAML `homeserver` is blanked, a root-owned tree, a late credential file never retried, `kill-sessions` before re-issue, and the s6 multiplex default.

- [ ] **Step 6: GREEN and validate.** `check-pr2.sh` passes; staged lefthook ✔; `flux-local test -A --path kubernetes/flux/cluster` passes.

- [ ] **Step 7: Commit, then PR when Derek asks.** Subject: `hermes: retire the canary profile, document adding an agent profile`.

---

### Task 9: Token-lifetime check (25h after Task 3)

**Files:** none.

- [ ] **Step 1:** At least 25h after Task 3 Step 2, the Bosun log shows no Matrix auth errors (`M_UNKNOWN_TOKEN`, 401) since the issue time, and Bosun still answers a DM.
  - Pass: compatibility tokens don't expire on a 24h scale. Record it in the README's Matrix section.
  - Fail: open a follow-up to give the adapter a refresh path or a re-issue CronJob. This blocks onboarding the other four agents.

---

## Execution notes

- Tasks 1–2 are code with render tests. Tasks 3–9 are live, ordered and gated, and most steps are Derek's. Each live task's "test" is its P-check, compared against the Expected lines, and recorded in the ledger.
- Stop and ask at every live write the agent would run: `register-user`, in-pod `config set`/`profile create`/`profile delete`, `chown`, a rollout restart. Derek runs every credential step.
