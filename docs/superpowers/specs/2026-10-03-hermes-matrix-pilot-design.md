# Hermes on Matrix: Bosun pilot and the per-profile secret pattern

**Status:** approved design (2026-10-03). Revised after two adversarial reviews against the live pod's source: the first moved the topology and P5 off the newer local checkout, and the second corrected the wiring. Neither changed the design.

**Follows:** [2026-10-02-matrix-bluevulpine-design.md](2026-10-02-matrix-bluevulpine-design.md). That spec made derekjacobs.dev the agent space and bluevulpine.net Derek's external identity, and deferred "bots and agents on the homeservers". This spec picks that up.

## Intent

Derek's agents should be reachable on Matrix, and able to speak there. Five agents are expected to run as **Hermes profiles**:

- **Bosun** runs on Hermes today.
- **Fizz, Pollen, Honey and Wasp** run in the Buzz harness today and will move to Hermes later ("probably not forever" on Buzz).

Two questions should be settled once, on real infrastructure, before onboarding four agents:

1. **Topology:** one Hermes container serving several profiles, or one container per agent?
2. **Plumbing:** how does a profile get its own Matrix identity and credentials, with encryption working end to end?

This spec is the pilot that answers both. It does **not** onboard Fizz, Pollen, Honey or Wasp; they follow the pattern it proves.

**Source of truth for behaviour claims:** the source **in the running image** (`/opt/hermes`, Hermes v0.21.4 / 2026.9.21). The image ships no `website/docs`. A newer local checkout behaves differently in ways that matter, notably the multiplex default on s6 hosts and per-profile parking. Every claim below cites pod source.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| How agents get onto Matrix | **Hermes' built-in Matrix gateway** (`plugins/platforms/matrix`, mautrix 0.21.1) | It already does E2EE, a stable device ID, cross-signing bootstrap, mention gating and allowlists, so agents can be woken from Matrix with nothing custom built. A Buzz-specific bridge would be thrown away when the agents move. |
| Topology | **One `ai/hermes` multiplexer, one profile per agent, multiplexing set *explicitly*** | Per-profile isolation (secret scope, `state.db`, memory, SOUL, adapters) is real in v0.21.4. The *implicit* default does **not** turn multiplexing on in this pod: `implicit_multiplex_blocker()` calls `_host_supports_migration()`, which refuses on s6 hosts, and PID 1 here is `s6-svscan`. An explicit `GATEWAY_MULTIPLEX_PROFILES=true` bypasses that check (`gateway_multiplex_mode.py`: `if current: return MultiplexDecision(True, "config")`). |
| Matrix identity | **One MAS account per agent, one device per process** | Created with `mas-cli manage register-user` and `issue-compatibility-token <user> <DEVICE_ID>`. The adapter uses the token through `whoami()` and never logs in itself. An `MATRIX_DEVICE_ID` that matches the token's device is accepted; if they differ, the token's device wins and an error is logged (`adapter.py:1124-1145`). |
| Encryption | **E2EE required** | Element encrypts DMs by default, and Derek will talk to the agents from `@bluevulpine:bluevulpine.net`. `olm`, `aiosqlite` and the mautrix crypto store all import cleanly in the pod. |
| Pilot subjects | **Bosun** (the default profile) and a throwaway named profile, **`canary`** | Named profiles cannot borrow the launch scope (`secret_scope.py:159-164`). `canary` exercises the mechanism the four agents will depend on, before the first of them does. |

## How a profile's secrets resolve (verified in `/opt/hermes`)

- **Default (launch) profile:** under multiplexing its scope is the frozen process environment **plus `/opt/data/.env`, and `.env` wins on conflict** (`tui_gateway/launch_profile_policy.py:129-145`).
  - The `envFrom: hermes-secret` Secret holds only `API_SERVER_KEY` and `HERMES_DASHBOARD_OIDC_CLIENT_ID`.
  - Bosun's model credential is in `auth.json` (`credential_pool.anthropic`) on the PVC.
  - `/opt/data/.env` holds only platform and terminal settings (`TELEGRAM_*`, `BUZZ_*`, `TERMINAL_*`, debug flags) and **no** `MATRIX_*` keys. That was checked by key names only.
  - This design makes OpenBao the source of truth **for the Matrix keys only**. `/opt/data/.env` must never gain `MATRIX_*` entries, because a copy there would shadow OpenBao. It has none today.
- **Named profile:** its scope comes from **its own** `.env` and its configured secret sources, and never from the process environment.
  - A `secrets.command` source in the profile's own `config.yaml` runs **per profile and scoped to it**. It is loaded lazily when that profile's config is first loaded, latched per profile home on success and retried on failure (`run_adapters.py:958-961`, `env_loader.py:114-176`).
  - A successful pull is latched per profile home until restart.
  - A failed pull stays retryable (`env_loader.py:163-167`).
  - A home with no `secrets:` block is never latched.
  - So a *changed* file is picked up only after a restart, and rotation relies on the pod rolling.
  - Schema: `{enabled, command, helper_timeout_seconds, override_existing}`. `override_existing` defaults to `false` (`command.py:158-166`).
  - The helper's environment is the profile's own view plus global variables, so use absolute paths (`/bin/cat`).
- **The Matrix adapter** reads every credential and identity value through the scoped reader, never `os.environ` (`adapter.py:48, 842-848`). Within a scope, a missing value falls back to the adapter's default, never to another profile's value.

## Design

### 1. Matrix identities (derekjacobs.dev, namespace `matrix`)

| Profile | Matrix user | Device ID |
|---|---|---|
| Bosun (default profile) | `@bosun:derekjacobs.dev` | `BOSUNHERMES` |
| canary (throwaway) | `@canary:derekjacobs.dev` | `CANARYHERMES` |

- Device IDs are plain alphanumeric. Whether MAS 1.26 accepts hyphens is unverified, and nothing is gained by finding out.
- Commands: `mas-cli manage register-user -y -d <Display> <user>`, then `mas-cli manage issue-compatibility-token <user> <DEVICE>`.
- **Never** pass `--yes-i-want-to-grant-synapse-admin-privileges`.
- **Derek runs the token step.** It pipes straight into `bao kv patch` and never prints the token. The agent's session is not permitted to write generated credentials into OpenBao.

### 2. Secret delivery

| | Bosun (default profile) | canary (named profile) |
|---|---|---|
| OpenBao | `secret/hermes`: `Hermes__Matrix__AccessToken`, `Hermes__Matrix__RecoveryKey` | `secret/hermes-canary`: the same two fields, plus a provider key (see below) |
| ExternalSecret | the existing `hermes-secret` template gains `MATRIX_ACCESS_TOKEN`, `MATRIX_RECOVERY_KEY`, `MATRIX_RECOVERY_KEY_OUTPUT_FILE`, plus the non-secret `MATRIX_HOMESERVER` and `MATRIX_E2EE_MODE` (see §3) | new `hermes-profile-canary`, which renders **one key**, `profile.env` (`KEY=VALUE` lines), carrying the same five `MATRIX_*` and canary's model key |
| In the pod | `envFrom` (unchanged mechanism) | mounted read-only **as a directory** at `/run/hermes-profiles/canary/` with `defaultMode: 0440`, **not** with `subPath`, which never receives Secret updates |
| How Hermes reads it | launch scope (process env) | canary's `config.yaml`: `secrets.command: {enabled: true, command: "/bin/cat /run/hermes-profiles/canary/profile.env", override_existing: true}` |
| Rotation | Reloader rolls the pod (`reloader.stakater.com/auto: "true"` is already set) | the same; the source reads once per process, so the roll is what applies the change |

- **Why `/run` and `0440` work:**
  - The root filesystem is a writable overlay, and `/run` is not a tmpfs.
  - The service-account token already mounts under `/run/secrets` and survives s6, which only uses `/run/s6*` and `/run/service`.
  - The gateway runs as uid/gid 10000 with group 10000 (`fsGroup`) and no capabilities, so a group-readable `0440` file is readable and nothing more is granted.
- **Why not mount into the profile's `.env`:**
  - Hermes writes its own `.env` (`save_env_value`, `/pair`, setup), so a read-only mount breaks those writes.
  - A copy on the PVC would drift from OpenBao.
- **canary needs its own model, not just its own key.**
  - `profile create` without `--clone` still seeds the launch profile's `model:` block (`profiles.py:655-668`). That block is Bosun's `provider: anthropic` at `api.anthropic.com`, and its credential lives in Bosun's `auth.json`, which canary can't reach.
  - canary's config step therefore **rewrites `model:`** to an OpenAI-compatible provider whose `base_url` is the in-cluster LiteLLM service. A dedicated, low-budget LiteLLM virtual key goes in `profile.env`, under the env name that provider reads.
  - Without this, canary connects to Matrix but fails every turn.
- **Values that are secret-reader-only go in the secret files, not `config.yaml`:**
  - `MATRIX_RECOVERY_KEY` and `MATRIX_RECOVERY_KEY_OUTPUT_FILE` are read **only** through the scoped secret reader (`adapter.py:543-545, 610-611`). Placed in `config.yaml` they are silently ignored.
  - Each profile gets a **distinct** output path. An existing file aborts the bootstrap with "exists", because the adapter opens it with `O_EXCL` (`adapter.py:549-573`).
- **Trust boundary:** the Hermes process can read every mounted profile file, so isolation between profiles is Hermes's logical isolation, not a kernel boundary. The per-profile `.env` files already sharing one PVC work the same way. This suits a family of Derek's own agents. An agent that needs a hard boundary gets its own pod (see "Escape hatch").

### 3. Hermes configuration

**Pod (in git, HelmRelease env):** `GATEWAY_MULTIPLEX_PROFILES: "true"`.
- Required, because the implicit default refuses on s6.
- Harmless while only Bosun exists.
- Keeps the behaviour stable across Renovate bumps; a newer Hermes changes the s6 rule.

**Per profile, non-secret.** Where each value goes is decided by the loader's precedence, not by taste. `load_gateway_config` applies the YAML layer first and the env/secret-scope overrides after it (`gateway/config.py:824` then `:841`). The Matrix credential step treats `homeserver` as a *fixed* key: it is "always written once enabled", as `extra.homeserver = getenv("MATRIX_HOMESERVER", "")` (`config_env.py:216, 240-243, 547`). A `homeserver` set only in YAML is therefore **blanked to `""`**, and `connect()` aborts with "homeserver URL not configured".

| Setting | Value | Where it goes | Note |
|---|---|---|---|
| `MATRIX_HOMESERVER` | `https://matrix.derekjacobs.dev` | **secret path** (Bosun: `hermes-secret` template; canary: `profile.env`) | Must come through env or scope, for the reason above. From namespace `ai`, cluster DNS resolves it to the **internal** gateway (172.16.8.2), so agent traffic stays on the LAN and never goes through Pangolin. There is no NetworkPolicy in `ai` or `matrix`. |
| `MATRIX_E2EE_MODE` | `required` | **secret path** | `_matrix_e2ee` overwrites `extra.encryption` from env (`config_env.py:295-300`). YAML `e2ee_mode` would still win in `_resolve_e2ee_mode` (`adapter.py:507-513`), but the value is set where it can't be clobbered. Fails closed: no silent plaintext. |
| `device_id` | `BOSUNHERMES` / `CANARYHERMES` | `platforms.matrix.device_id` in the profile's `config.yaml` | Survives the env pass, which only writes `_env_extras` when set. Must equal the token's device. |
| `allowed_users` | `@bluevulpine:bluevulpine.net` | `platforms.matrix.allowed_users` in the profile's `config.yaml` | Closed by default. Verified: the gateway's `_principal_authorized` applies the platform allowlist to DMs too (`authz_mixin.py:648-700`). `MATRIX_ALLOWED_ROOMS` is the only list that exempts DMs. Caveats: an approved pairing is granted *in addition to* the list, and `MATRIX_ALLOW_ALL_USERS` overrides it. Neither is to be set. |

**Profile CLI steps run as the gateway user.** `kubectl exec` enters as **root**, and the `hermes` CLI does not drop privileges. Run as root, `hermes profile create` leaves a root-owned profile tree with a `0600` `.env`. The gateway (uid 10000) could then read neither its `.env` nor create `platforms/matrix/store`, and with E2EE required the connect aborts. Every profile step runs as `kubectl -n ai exec deploy/hermes -- s6-setuidgid hermes hermes …`.

The `canary` profile and its `config.yaml` are created in the pod, onto the PVC, matching how Bosun's config lives today:
- `hermes profile create canary`, without `--clone`, copies no credentials (`profiles.py:1096-1122`).
- It registers an s6 slot with `start_now=False`, and the boot reconciler never starts named slots (`container_boot.py:129-135`). So no second gateway appears.

Only the **secret plumbing and the multiplex flag** go in git.

### 4. Ordering

How the multiplexer behaves:
- **Decision:** made once, at boot (`load_gateway_config_for_runner`, `run.py:1856-1858`). The fail-closed scope switch is at `run.py:3490`.
- **Hot-add and remove:**
  - These only run inside a multiplexer. `run_profile_reconcile.py` polls every 30s, and `profile create` and `profile delete` also nudge it over the control socket (`profiles.py:1181, 1554`).
  - A profile whose bot credential is **missing** when it is first loaded is skipped and its signature acknowledged (`run_adapters.py:1069-1075`, `run_profile_reconcile.py:131`).
  - The signature covers only `config.yaml` and `.env`, **not** the mounted `profile.env`. A credential file that arrives late is therefore never retried until `config.yaml` is touched.

Order:
1. **Merge PR 1:** `GATEWAY_MULTIPLEX_PROFILES`, Bosun's `MATRIX_*`, canary's ExternalSecret and mount. Bosun's and canary's OpenBao keys must be populated **before** the merge, including the provider key and the canary token.
2. **P0.**
3. Bosun's Matrix adapter comes up: P1, P2. The recovery key goes into OpenBao **before** any later step.
4. **Precondition:** `/run/hermes-profiles/canary/profile.env` exists in the pod with the expected key *names*. Then create `canary` and write its config, as the gateway user, in one step. Then P3, P4, P5. If canary comes up adapter-less, touch its `config.yaml` to force a rescan.
5. P6, then cleanup.

### 5. Pass/fail criteria

| # | Proves | Check |
|---|---|---|
| P0 | Topology | An explicit flag logs **nothing** (`log_multiplex_decision` is silent for source `config`), so the check reads state, not a log line. After the merge, `/opt/data/gateway_state.json` has `served_profiles == ["default"]` and `multiplex_standalone_reason == null` (today: `[]` and "only one profile exists"). That boot logs neither "Single-profile install" nor "stays standalone". Once canary exists, `served_profiles == ["default","canary"]`, and there is exactly **one** gateway process in the pod. |
| P1 | Matrix + E2EE + federation | Derek sends an **encrypted** DM from `@bluevulpine:bluevulpine.net` to `@bosun:derekjacobs.dev`. Bosun replies and the reply decrypts in Element. |
| P2 | Cross-signing behind MAS | The recovery key is written once to its output file, moved into OpenBao (`…__RecoveryKey`), and the file is deleted. Bosun's device shows as verified by its owner. Expected to pass: Synapse 1.162 with MAS only demands approval `if is_cross_signing_setup`, so the **first** upload needs no UIA (`keys.py:536-544`), and mautrix uploads with `auth=None`. |
| P3 | Per-profile identity | canary connects as `@canary`, from **its own** mounted file only. Status shows two Matrix adapters with distinct user IDs. No `duplicate_credential`. |
| P4 | Secret isolation and gating | Neither profile's turns can resolve the other's token. Checked through Hermes status and logs, never by printing a token. canary answers using **its own** provider key: LiteLLM's spend log shows canary's turn against canary's virtual key, not Bosun's. A DM to `@canary` from an account **not** in `allowed_users` gets no turn (it is ignored, or gets a pairing prompt). |
| P5 | Live add and remove | v0.21.4 has **no** per-profile park/unpark; `hermes -p canary gateway stop` exits 78 under a multiplexer. So the test is: canary is **hot-added** without a restart (log: `[MULTIPLEX] Now serving profile 'canary' (N adapter(s) connected; …)`), and later **removed** by `hermes profile delete canary` (log: `[MULTIPLEX] Profile 'canary' deleted — N adapter(s) stopped and unrouted`). Bosun's Matrix connection stays up throughout. |
| P6 | Rotation | `mas-cli manage kill-sessions canary` **first** (it revokes every session for the user), then `issue-compatibility-token canary CANARYHERMES` for the **same** device ID (a different device would reset the crypto store: `adapter.py:990-1006`), then `bao kv patch`. ExternalSecret sync → Reloader roll → canary reconnects with its crypto state intact. The roll is a **whole-pod** restart (`strategy: Recreate`), so **every agent, Bosun included, drops briefly**: rotating any agent's credential restarts all of them. `kill-sessions` likely deletes the device on Synapse. The adapter re-uploads device keys (`adapter.py:1093-1096`), and re-signing relies on `MATRIX_RECOVERY_KEY` already being in canary's scope (`adapter.py:1271-1277`), so canary's recovery key must be in OpenBao **before** P6. Pass = the device is verified by its owner again after the roll, with no new device ID. Also check here (not settled read-only) that Reloader reacts to a change in a **volume-only** Secret. |

### 6. Cleanup (part of the pilot, not optional)

- `hermes profile delete canary`. In MAS: `kill-sessions canary`, then `lock-user canary`.
- Remove canary's ExternalSecret and mount from git, and delete `secret/hermes-canary`. Revoke canary's LiteLLM key.
- Write the proven pattern into `kubernetes/apps/ai/hermes/README.md` under "Adding an agent profile":
  - the identity commands
  - the OpenBao layout
  - the ExternalSecret and mount
  - the profile config
  - the order of steps
  - the pass checks
  
  Fizz, Pollen, Honey and Wasp are then onboarded by following it.

Bosun stays on Matrix.

## Risks

- **Losing the crypto store after cross-signing exists.** Once cross-signing is set up, Synapse requires MAS approval to replace it (`SigningKeyUploadServlet`). The bootstrap's failure is non-fatal, so the device would quietly stay unverified. The crypto store lives on the PVC, per profile, at `<HERMES_HOME>/platforms/matrix/store/crypto.db` (`adapter.py:396-399, 822-830`), and the recovery key goes into OpenBao. Together these cover it. Never delete a store without the recovery key in hand.
- **Shared blast radius.** One process means one crash or restart drops every agent briefly, and one runaway turn can starve the rest. Bosun alone uses 853Mi of a 6Gi limit today; watch memory as profiles are added.
- **Process-global state in the multiplexer:** MCP tool discovery, the built-in tool registry and `TERMINAL_*` sandbox env. Acceptable for agents of equal trust. For an agent with different trust, this is a reason to give it its own pod.
- **Hermes upgrades.** Multiplexing is changing fast upstream; a newer build changes the s6 rule and adds parking. Renovate bumps of `hermes-agent` must be smoke-tested against P0, P3 and P5. The explicit env flag protects P0.
- **Compatibility-token lifetime is unverified.** If CLI-issued tokens expire, an agent would go deaf with no refresh path in the adapter. The plan checks the expiry of the first issued token before relying on it.

## Escape hatch

An agent that needs harder isolation runs as its own Deployment: same image, its own PVC, with its profile as that pod's default profile. Its ExternalSecret then moves to `envFrom`. The Matrix identity, device and OpenBao layout stay the same, so moving it costs no re-provisioning.

## Out of scope

- Onboarding Fizz, Pollen, Honey and Wasp. They follow the README pattern once the pilot passes.
- Matrix application services and namespaced ghost users.
- Agents on the bluevulpine.net homeserver. Agents live on derekjacobs.dev and reach bluevulpine.net through federation.
- Wider `allowed_users`, and agent-to-agent rooms. These are policy decisions for after onboarding.
