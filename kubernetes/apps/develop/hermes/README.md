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
kubectl -n develop exec -it deploy/hermes -- hermes setup
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
logged in can use it. For several agents in this one pod, set
`gateway.multiplex_profiles: true` on the default profile — upstream recommends it
specifically for container deployments, where one process per profile is heavy.

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
