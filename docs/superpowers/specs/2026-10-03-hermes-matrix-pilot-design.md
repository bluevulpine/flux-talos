# Hermes on Matrix — Bosun pilot and per-profile secret pattern

**Status:** approved design (2026-10-03)  
**Follows:** [2026-10-02-matrix-bluevulpine-design.md](2026-10-02-matrix-bluevulpine-design.md). That spec made derekjacobs.dev the agent space and bluevulpine.net Derek's external identity, and it deferred "bots and agents on the homeservers" to a later piece of work. This is that work.

## Intent

Derek's agents should be reachable on Matrix, and be able to speak there. Five agents are in scope, all expected to run as **Hermes profiles**:

- **Bosun**, which runs on Hermes today.
- **Fizz, Pollen, Honey and Wasp**, which run in the Buzz harness today and will move to Hermes later ("probably not forever" on Buzz).

Before onboarding four agents, two things need to be settled and proven once, on real infrastructure:

1. **Topology:** one Hermes container serving several profiles, or one container per agent.
2. **Plumbing:** how a profile gets its own Matrix identity and credentials, with encryption working end to end.

This spec is the pilot that settles both. It does **not** onboard Fizz, Pollen, Honey or Wasp; that comes afterwards, by following the pattern this pilot proves.

## Decisions (settled before this spec)

| Decision | Choice | Why |
|---|---|---|
| Harness for agents on Matrix | **Hermes' built-in Matrix gateway** (`plugins/platforms/matrix`, mautrix) | Already ships E2EE, a stable device ID, cross-signing, mention gating and allowlists. Agents can be woken from Matrix out of the box, with no custom MCP server or bridge to build. A Buzz-specific bridge would be thrown away when the agents move. |
| Topology | **One `ai/hermes` multiplexer, one profile per agent** | Hermes ≥ 2026.9 makes multiplexing the default (`gateway.multiplex_profiles`), and per-profile gateways are being retired: a named profile's `gateway install` exits 78. Each profile keeps its own secrets, `state.db`, memory, SOUL and adapters. Verified in the live pod: v0.21.4 (2026.9.21) has `gateway_multiplex_mode.py` and `secret_scope.py`. |
| Matrix identity | **One MAS account per agent, one device per process** | `mas-cli manage register-user` plus `issue-compatibility-token <user> <DEVICE_ID>`. No Authentik user is needed, and Authentik is browser-only anyway. Naming devices per process means adding a second consumer later only takes a second token for the same account. |
| Encryption | **E2EE required** | Element encrypts DMs by default, and Derek will talk to the agents from `@bluevulpine:bluevulpine.net`. Without encryption, every agent conversation would need a workaround. The image already has mautrix 0.21.1 and python-olm. |
| Pilot subject | **Bosun**, plus a **throwaway named profile `canary`** | Bosun is the default profile, so its secrets come in as process env. Named profiles **cannot** use process env under multiplexing (see below). `canary` exercises the mechanism the four agents will actually depend on, before the first of them does. |

## How Hermes resolves a profile's secrets (the constraint that shapes this design)

From `website/docs/developer-guide/multiplexing-gateway.md` and `agent/secret_scope.py` in the running version:

- Under multiplexing, each turn and each adapter runs inside a secret scope built from **that profile's** `.env` and its configured secret sources. Nothing is ever written to `os.environ`.
- The process environment is frozen as the **launch (default) profile's** credentials. A named profile resolves from its own files only. A secret it lacks is **absent**; it is never borrowed from the default profile.
- Today every credential reaches the pod through `envFrom: hermes-secret`, which is process env. That works for Bosun and **cannot** work for a named profile.

So a named profile needs its credentials delivered as a file it owns, or through a secret source.

## Design

### 1. Matrix identities (derekjacobs.dev, namespace `matrix`)

| Profile | Matrix user | Device | Admin |
|---|---|---|---|
| Bosun (default) | `@bosun:derekjacobs.dev` | `BOSUN-HERMES` | no |
| canary (throwaway) | `@canary:derekjacobs.dev` | `CANARY-HERMES` | no |

Create them with `mas-cli manage register-user -y -d <Display> <user>`, then `mas-cli manage issue-compatibility-token <user> <DEVICE>`. **Never** pass `--yes-i-want-to-grant-synapse-admin-privileges`.

**Derek runs the token step.** The agent's session is not allowed to write generated credentials into OpenBao. The token is piped straight into `bao kv patch` and never printed.

### 2. Secret delivery

| | Bosun (default profile) | canary (named profile) |
|---|---|---|
| OpenBao | `secret/hermes`, new fields `Hermes__Matrix__AccessToken`, `Hermes__Matrix__RecoveryKey` | `secret/hermes-canary`, same field names |
| ExternalSecret | existing `hermes-secret`, with `MATRIX_ACCESS_TOKEN` and `MATRIX_RECOVERY_KEY` added to the template | new `hermes-profile-canary`, rendering **one key**, `profile.env`, which holds the profile's `KEY=VALUE` lines |
| In the pod | `envFrom` (unchanged) | Secret mounted read-only **as a directory** at `/run/hermes-profiles/canary/`. Not `subPath`: a subPath mount never receives Secret updates. |
| How Hermes reads it | process env | the profile's `config.yaml`: `secrets.command.enabled: true`, `command: "cat /run/hermes-profiles/canary/profile.env"`, `override_existing: true` |
| Rotation | Reloader restarts the pod (`reloader.stakater.com/auto: "true"` is already on the controller) | the same. The command source runs **once at startup**, so the restart is what applies a new value. |

**Why not mount into the profile's `.env`:**
- Hermes writes to its own `.env` (`save_env_value`, `/pair`, setup flows), so a read-only mount there breaks those writes.
- A copy written onto the PVC would drift from OpenBao.

The command source keeps OpenBao as the single source of truth (`override_existing: true`), keeps credentials out of `.env`, and needs nothing on the PVC except the one-line command in config.

**Trust boundary, stated plainly:** the Hermes process can read every mounted profile file. Isolation between profiles is Hermes's own logical isolation (secret scopes), not a kernel boundary. The same is true of the per-profile `.env` files that already share one PVC. This suits a family of Derek's own agents. An agent that needs a hard boundary gets its own pod; see "Escape hatch".

### 3. Hermes configuration (non-secret)

Set per profile, in that profile's own config. The default profile is `/opt/data`; canary is `/opt/data/profiles/canary`.

| Setting | Value | Note |
|---|---|---|
| `MATRIX_HOMESERVER` | `https://matrix.derekjacobs.dev` | Verified from namespace `ai`: in-cluster DNS resolves it to the **internal** gateway (172.16.8.2), so traffic stays on the LAN and never goes through Pangolin. The haproxy Service only exposes 8405 (stats), so the public hostname is the correct choice, not just the convenient one. |
| `MATRIX_E2EE_MODE` | `required` | Fails closed: the adapter refuses to run without working crypto rather than silently going plaintext. |
| `MATRIX_DEVICE_ID` | `BOSUN-HERMES` / `CANARY-HERMES` | Must equal the device the compatibility token was issued for. |
| `MATRIX_ALLOWED_USERS` | `@bluevulpine:bluevulpine.net` | Closed by default: only Derek can wake a pilot agent. The adapter source says DMs are exempt from `MATRIX_ALLOWED_ROOMS`; that `MATRIX_ALLOWED_USERS` **does** still gate DMs is an inference. The plan verifies it with a DM from a non-allowed account. |
| `MATRIX_RECOVERY_KEY_OUTPUT_FILE` | a 0600 path on the PVC, used for the **first boot only** | Hermes writes the bootstrapped cross-signing recovery key there once. Derek moves it into OpenBao (`…__RecoveryKey`) and the file is deleted. |

`canary` is created in the pod with `hermes profile create canary`, and its `config.yaml` is written there too. This matches how Bosun's own config lives on the PVC today. Only the **secret plumbing** goes in git: the ExternalSecret, the mount, and the README pattern.

### 4. Pass/fail criteria

| # | Proves | Check |
|---|---|---|
| P1 | Matrix + E2EE + federation | Derek sends an **encrypted** DM from `@bluevulpine:bluevulpine.net` to `@bosun:derekjacobs.dev`, Bosun replies, and the reply decrypts in Element. |
| P2 | Cross-signing behind MAS | The recovery key is written to the output file and stored in OpenBao, and Bosun's device shows as **verified by its owner** in Element. If MAS refuses the upload, see Risks. |
| P3 | Per-profile identity | `canary` connects as `@canary` using **only** its mounted file. Hermes status shows two Matrix adapters, each with its own user ID. No `duplicate_credential`. |
| P4 | Secret isolation | Bosun's turn cannot resolve canary's token and canary's turn cannot resolve Bosun's. Checked through Hermes's own status and logs, never by printing a token. |
| P5 | Per-profile lifecycle | `hermes -p canary gateway stop`, then `start`, parks and unparks canary while Bosun stays connected throughout. |
| P6 | Rotation | Issue canary a new token, `bao kv patch` it, and see the ExternalSecret sync, Reloader roll the pod, and canary reconnect on the new device token. The old token is revoked (`kill-sessions`). |

### 5. Cleanup (part of the pilot, not optional)

- `hermes profile delete canary`.
- In MAS: `kill-sessions canary`, then `lock-user canary`.
- Remove `hermes-profile-canary` (the ExternalSecret and the mount) from git. Delete `secret/hermes-canary`.
- Write the proven pattern into `kubernetes/apps/ai/hermes/README.md` under "Adding an agent profile": the identity commands, the OpenBao key layout, the ExternalSecret and mount, the profile config, and the pass checks. Fizz, Pollen, Honey and Wasp are then onboarded by following it.

Bosun stays on Matrix after the pilot.

## Risks

- **Cross-signing upload under MAS (MSC3861).** This is the genuine unknown. Synapse with delegated auth normally allows the *first* cross-signing upload without UIA, but that hasn't been proven here. **Fallback:** E2EE without cross-signing still encrypts; Element shows the device as unverified. P2 then becomes a recorded limitation, not a blocker for onboarding the other agents.
- **Shared blast radius.** One process means one crash or restart drops every agent briefly, and one runaway turn can starve the others. Current use is 853Mi out of a 6Gi limit. Watch it as profiles are added.
- **Process-global state the docs list as not yet profile-scoped:** MCP tool discovery (upstream #67605), the built-in tool registry, `TERMINAL_*` sandbox env. This is acceptable for agents with equal trust. It is a reason to move a differently trusted agent to its own pod.
- **Hermes upgrades.** Multiplexing and secret scoping are recent and still changing upstream (`gateway.standalone` is a "temporary shim"). Renovate bumps of `hermes-agent` should be smoke-tested against P3 and P5.

## Escape hatch

An agent that needs harder isolation runs as its own Deployment: same image, its own PVC, its profile as that pod's default profile. Its ExternalSecret then becomes `envFrom`. The Matrix identity, the device and the OpenBao key layout are unchanged, so moving out costs no re-provisioning.

## Out of scope

- Onboarding Fizz, Pollen, Honey and Wasp. That follows the README pattern once the pilot passes.
- Matrix application services and namespaced ghost users. Revisit only if agents become numerous or short-lived.
- Agents on the bluevulpine.net homeserver. Agents live on derekjacobs.dev and reach bluevulpine.net through federation.
- Tightening `MATRIX_ALLOWED_USERS` beyond Derek, and agent-to-agent rooms. Both are policy decisions for after onboarding.
