# hermes

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) running as a
supervised gateway with the built-in web dashboard, authenticated against Authentik
over standard OIDC.

## Why in-cluster and not the TrueNAS app

TrueNAS ships a one-click community-train app (`ix-dev/community/hermes-agent`), and
it is genuinely well maintained — the catalog tracks upstream within 0–1 days. It was
rejected on blast radius, not on quality.

TrueNAS is what this cluster *recovers from*: tns-csi serves every NFS/iSCSI/NVMe-oF
PV, and Garage holds Thanos, CNPG backups, VolSync snapshots, and the Talos etcd
backups. An agent with a `terminal` tool does not belong on the recovery asset. The
availability argument for putting it on the NAS ("the cluster can't restart it") is
real but narrow — with 7 nodes it only matters when the agent reboots its *own* node,
which `approvals.deny` covers, or when the whole cluster is down, which is not a job
for an LLM agent.

## Decisions worth not re-litigating

**`strategy: Recreate`.** Upstream: *"Never run two Hermes gateway containers against
the same data directory simultaneously — session files and memory stores are not
designed for concurrent write access."* A RollingUpdate would briefly run two pods
against one RWO PVC.

**Runs as root, drops to uid 10000.** This is the one app here that does not use the
usual `runAsNonRoot: true`. The image entrypoint is an s6-overlay dispatcher that must
start as root to fix ownership on `/opt/data` before dropping. `CHOWN`, `DAC_OVERRIDE`,
`SETGID`, `SETUID` are exactly what that drop needs and everything else is dropped —
the same set the TrueNAS catalog app grants. `HERMES_ALLOW_ROOT_GATEWAY` is **not**
set, so the agent process itself never runs as root.

**API server on container loopback.** The dashboard talks to the gateway over the
OpenAI-compatible API on 8642, so it cannot be switched off — but `API_SERVER_HOST` is
`127.0.0.1`, so it never listens on the pod IP and is not in the Service. That closes
the unattended-approval surface (see below) by construction. The liveness probe is
therefore `exec`+`curl`, not `httpGet`: kubelet probes the pod IP, which has nothing
listening on 8642.

**One hostname.** `HERMES_DASHBOARD_PUBLIC_URL` adds its exact host to the dashboard's
Host / WebSocket-Origin guard, so a second entry point (a Tailscale MagicDNS name, say)
would be rejected at the WebSocket handshake. There is no `tailscale` GatewayClass in
this cluster anyway — only `envoy`. Tailnet clients reach the same internal HTTPRoute:
the `ts-exit-node` Connector advertises `172.16.8.0/24` and the internal gateway is
`172.16.8.2`.

**`longhorn-1-replica-local`.** `dataLocality: best-effort` keeps the single replica on
the pod's node without the hard pin of strict-local, so a Talos drain can still move the
agent and rebuild locally. VolSync provides the redundancy — `Snapshot` copyMethod,
because the mover cannot co-mount an RWO volume the agent holds and a `Direct` copy
would read a live SQLite `state.db` mid-write.

**No ServiceAccount token.** app-template sets `automountServiceAccountToken: false`.
The agent starts with **no** cluster credentials. Giving it kubectl/talosctl access is a
deliberate, separate act — see below.

## First boot is not zero-touch

The image ships `docker-cli`, `openssh-client`, node 26 and `uv`, but **no kubectl, helm,
or talosctl**, and `/opt/hermes` is read-only. There is also no provider config until you
create one.

```sh
kubectl -n ai exec -it deploy/hermes -- hermes setup
```

Anything that must survive a restart goes under `/opt/data` (which is `HERMES_HOME`);
`/tmp` is an emptyDir and is not persisted.

## The LLM credential is deliberately NOT in the ExternalSecret

Both supported Anthropic paths establish the credential inside `/opt/data`, not via env:

- **OAuth (Claude Max)** writes a refreshable token to `auth.json`, which Hermes rewrites
  on every refresh. There is no env-var form of it, so an ExternalSecret cannot carry it.
- **API key** can come from env — but if `ANTHROPIC_API_KEY` is set, the credential-pool
  loader auto-seeds a pool entry from it. A placeholder or stale value therefore does not
  sit inert; it becomes a selectable credential that fails at call time.

So `hermes setup` (or the dashboard's API Keys page, which edits the same `.env` on the
PVC) owns this, and the PVC is backed up by VolSync. This is a deliberate deviation from
the repo's usual "every secret via OpenBao" pattern — the alternative is an env var that
can silently poison the credential pool.

**Read the billing note before choosing OAuth.** Upstream is explicit: the Anthropic OAuth
path *"only works if you're on a Claude Max plan and have purchased extra usage credits.
The base Max plan allowance (the usage included in Claude Code by default) is not consumed
by Hermes — only the extra/overage credits you've added on top are."* Claude Pro cannot
use this path at all.

## Authentik

Register a **public** OIDC application with authorization-code + PKCE (S256) — the
`self_hosted` dashboard-auth plugin does not support confidential clients, so there is
no client secret.

- Redirect URI: `https://hermes.${SECRET_DOMAIN}/auth/callback`
- Issuer: `https://sso.${SECRET_DOMAIN}/application/o/hermes/`

**`offline_access` is required, and is not the plugin default.** The bundled scopes are
`openid profile email`. Without `offline_access` Authentik issues no refresh token, and the
dashboard — which stores the ID token as the session credential and re-verifies it on every
request — expires at the ID token's `exp`. Authentik ties that to `access_token_validity`,
which defaults to **5 minutes**, so the symptom is a full interactive re-login every five
minutes. Raising `access_token_validity` is the wrong fix: Gitea and Grafana run the same
5-minute setting happily, because they mint their own app session after the handshake
instead of re-checking the IdP per request. The `offline_access` scope mapping must also be
assigned to the provider in Authentik for the request to be granted.

`groups` is requested too: the plugin fills `Session.org_id` from `org_id`/`organization`,
falling back to a joined `groups` claim, so without the scope that field is empty. It is
presentation only — there is still no authorization decision made from it.

**This trades a short expiry for a renewable one — know what that costs.** Before the scope
was requested, the 5-minute ID token put an incidental 5-minute ceiling on a stale session.
With a refresh token the session is silently renewable for up to `refresh_token_validity`,
**30 days** on this provider. Because the gate authenticates but does not authorize (below),
deprovisioning a user in Authentik no longer ends their dashboard session on its own —
revoke the token or the Authentik session too. That is the normal OIDC bargain and the
5-minute ceiling was never a real access control, but it was doing something, and this
removes it.

**The OIDC gate authenticates but does not authorize.** Hermes has no dashboard-side
user allowlist — any identity Authentik issues an ID token for gets in. Restrict access
with an Authentik policy/group binding on the application, not in this repo.

If the ExternalSecret has not synced, the dashboard **refuses to start** rather than
serving unauthenticated: a non-loopback bind with no registered auth provider is a hard
fail-closed error. A CrashLoop right after first deploy usually means the secret is
missing, not that the config is wrong.

## Multiple users

Not in the way the word usually means. One gateway is one operator console: everyone who
logs in shares the same sessions, memory, API keys, Config and Skills pages. The OIDC
session carries `user_id` / `email` / `org_id` (from group claims), but nothing is
partitioned by it.

**Profiles** are the isolation unit — separate `config.yaml`, `.env`, `SOUL.md`, memory,
sessions, skills and cron per profile, with credentials never shared across them. They
are per-*agent*, not per-*person*; the dashboard has a profile switcher and anyone
logged in can use it. This pod runs several agents as profiles of one multiplexing
gateway. That is switched on by `GATEWAY_MULTIPLEX_PROFILES: "true"` in the
HelmRelease env, **not** left to the implicit default, which refuses under s6. See
"Adding an agent profile" below.

## Before giving it cluster access

`approvals.unattended_mode` defaults to `deny` for `api_server` / `webhook` sessions —
there is no human to answer, so dangerous commands are refused instantly. Interactive
surfaces (this dashboard, Telegram, Discord, Slack) route approvals to real buttons and
work normally. Do not flip `unattended_mode` to `approve` to "make automation work": that
is YOLO for anything that reaches the endpoint.

When you do hand it a kubeconfig or talosconfig, add `approvals.deny` globs for its own
node in both hostname and `10.0.10.x` form. That list is consulted **before** `--yolo`
and `approvals.mode: off`. It is a guardrail, not a boundary — glob matching on shell
strings is dodgeable — so it covers the accident, not the adversary.

## Matrix

Agents talk on the derekjacobs.dev homeserver (`kubernetes/apps/matrix`) as their own
users, via Hermes' built-in Matrix gateway with **E2EE required**. Bosun (the default
profile) is `@bosun:derekjacobs.dev`, device `BOSUNHERMES`. Wasp is `@wasp:derekjacobs.dev`,
device `WASPHERMES`. Design and evidence:
`docs/superpowers/specs/2026-10-03-hermes-matrix-pilot-design.md`.

**The identity is a MAS account plus a compatibility token, not an Authentik user.**
Authentik login is browser-only, so agents use a token instead:
`mas-cli manage register-user` followed by `issue-compatibility-token <user> <DEVICE>`.
That gives one device per process, so a second consumer later only needs a second
token for a new device ID on the same account. Never pass
`--yes-i-want-to-grant-synapse-admin-privileges`.

Where each setting must live. This is decided by the loader, not by preference:

| Setting | Where | Why |
| --- | --- | --- |
| `MATRIX_ACCESS_TOKEN`, `MATRIX_RECOVERY_KEY` | OpenBao → secret path | They are credentials. |
| `MATRIX_HOMESERVER`, `MATRIX_E2EE_MODE=required` | secret path too | The adapter's credential pass rewrites `extra.homeserver` from `MATRIX_HOMESERVER`, so a YAML-only homeserver is blanked to `""` and `connect()` aborts. |
| `MATRIX_RECOVERY_KEY_OUTPUT_FILE` | secret path, a **per-profile** path | It is read only through the scoped secret reader. The file is opened `O_EXCL`, so it must not exist when the profile first boots. |
| `platforms.matrix.device_id`, `platforms.matrix.allowed_users` | the profile's `config.yaml` | These survive the env pass. |

The "secret path" is process env via `hermes-secret` for the default profile (Bosun), and
the mounted `profile.env` for a named profile (see below). **Never put `MATRIX_*` in
`/opt/data/.env`.** In the launch scope `.env` beats process env, so it would shadow
OpenBao.

**First boot bootstraps cross-signing** and writes the recovery key to the output file.
Move it into OpenBao straight away; it is piped, never printed. Then delete the file and
force-sync the ExternalSecret. Until that happens, a second restart would try to bootstrap
again and fail on the existing file. Once the key is stored, restarts verify silently.

**Federation with bluevulpine.net needs three non-obvious pieces** (#2059, #2062):
- Synapse `hostAliases` pin both `matrix.*` hosts to the Pangolin VPS.
- CoreDNS answers the `bluevulpine.net.` zone from public DNS.
- Synapse runs with `ndots:1`.

All three exist because split-horizon DNS hands Synapse the internal gateway, and
Synapse's SSRF guard refuses it. **Do not** "fix" that with `ip_range_whitelist`:
`172.16.8.2` fronts every LAN-only route, and the whitelist also governs pushers.

**Known limits:**
- **Element's "Verify User" (interactive verification) cannot complete.** The adapter has
  no SAS handler. The device is still cross-signed by the agent's own key, which is what
  matters for encryption.
- **The first message of the very first DM between two servers that have never met can
  be undecryptable.** Element encrypts before it knows the remote device. This happens
  once per server pair, not once per DM.
- **Rotating any agent's credentials restarts every agent.** Reloader rolls the whole pod
  (`strategy: Recreate`), and Bosun drops too.

## Adding an agent profile

One pod, one multiplexing gateway, one Hermes profile per agent. Each profile gets its
own secret scope, `state.db`, memory, SOUL and Matrix adapter. Wasp (#2057, #2064) is the
worked example. `<agent>` is lowercase (`pollen`); `<Agent>` is the OpenBao field prefix
(`Pollen`); `<DEVICE>` is uppercase alphanumeric (`POLLENHERMES`).

**Why a file and not env:** under multiplexing, the process environment is the *default*
profile's credentials only. A named profile resolves secrets from its own files and
never borrows. So its secrets arrive as a mounted `profile.env`, read by the profile's
own `secrets.command`. The mount is a directory, **not** a `subPath`, because a `subPath`
mount never receives Secret updates.

1. **Identity.** The agent runs the token step itself and pipes the token straight into
   OpenBao; it is never printed:
   ```bash
   kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- \
     mas-cli manage register-user -y -d <Agent> <agent>
   T=$(kubectl -n matrix exec deploy/matrix-stack-matrix-authentication-service -- \
     mas-cli manage issue-compatibility-token <agent> <DEVICE> 2>&1 | grep -o 'mct_[A-Za-z0-9_]*' | head -1)
   [ -n "$T" ] && bao kv patch secret/hermes-<agent> <Agent>__Matrix__AccessToken="$T" <Agent>__Matrix__RecoveryKey=; unset T
   ```
   - Use `patch`. `bao kv put` on an existing path **replaces every field**. Use `put`
     only for a brand-new path.
   - Seed every field the template references, even empty ones. A missing field fails
     the v2 template, and with it the whole Secret.
   - `/bin/bash` lacks `BAO_ADDR`, so export it.
2. **Git (one PR):**
   - `app/externalsecret-profile-<agent>.yaml` renders one key, `profile.env`. Copy
     Wasp's.
   - A `<agent>-secrets` persistence entry in `helmrelease.yaml`: `type: secret`,
     `defaultMode: 0440`, mounted at `/run/hermes-profiles/<agent>`, `readOnly`.
   - Add the ExternalSecret to `kustomization.yaml`.
3. **Merge, then confirm the file is in the pod** before `profile create`. A
   credential that arrives later is never retried, because the rescan signature only
   covers `config.yaml` and `.env`:
   `kubectl -n ai exec deploy/hermes -- cut -d= -f1 /run/hermes-profiles/<agent>/profile.env`
4. **Create and configure the profile as the gateway user.** `kubectl exec` is root, the
   CLI does not drop privileges, and a root-owned profile tree breaks the E2EE store:
   ```bash
   H=(kubectl -n ai exec deploy/hermes -- /command/s6-setuidgid hermes hermes)
   "${H[@]}" profile create <agent>        # no --clone: copies no credentials
   "${H[@]}" -p <agent> config set secrets.command.enabled true
   "${H[@]}" -p <agent> config set secrets.command.command "/bin/cat /run/hermes-profiles/<agent>/profile.env"
   "${H[@]}" -p <agent> config set secrets.command.override_existing true
   "${H[@]}" -p <agent> config set platforms.matrix.device_id <DEVICE>
   "${H[@]}" -p <agent> config set platforms.matrix.allowed_users "@bluevulpine:bluevulpine.net"
   ```
   - `profile create` seeds the *default* profile's `model:` block (Bosun's Anthropic),
     whose credential the new profile cannot reach. Set the agent's own model and
     provider key.
   - `s6-setuidgid` lives in `/command`. It is not on the `kubectl exec` PATH.
   - Set `allowed_users` **before** the token reaches the profile, so the adapter
     comes up closed.
5. **Checks:**
   - **Live add:** `/opt/data/gateway_state.json` `served_profiles` gains `<agent>`, and
     there is still exactly one gateway process.
   - **Adapter:** the log shows the agent's Matrix adapter connected as `@<agent>`, with
     no `duplicate_credential`.
   - **Ownership:** `find /opt/data/profiles/<agent> ! -uid 10000` prints nothing.
   - **Recovery key:** move it into OpenBao (see "Matrix" above).
   - **Gating:** an encrypted DM from an allowed user gets a reply. A DM from anyone
     else logs `rejecting invite … from unauthorized user`.
6. **Rotating a token:**
   - Run `mas-cli manage kill-sessions <agent>` **first**. It revokes every session for
     the user, so running it after the re-issue would kill the new token too.
   - Then `issue-compatibility-token <agent> <DEVICE>` for the **same device**. A new
     device ID resets the agent's crypto store.
   - Then patch OpenBao and force-sync the ExternalSecret.
   - Reloader rolls the pod even though the Secret is volume-only (verified), and the
     adapter re-uploads keys and re-signs the device with the stored recovery key.
     Every agent restarts.

Isolation between profiles is Hermes's logical isolation, not a kernel boundary. The
process can read every mounted `profile.env`. That suits agents of equal trust. An agent
that needs a hard boundary gets its own Deployment, with its profile as that pod's
default profile and the same identity and OpenBao layout.
