# buzz

Self-hosted [Buzz](https://github.com/block/buzz) relay (Block's Nostr-based agent
workspace) at `wss://buzz.${SECRET_DOMAIN}`. It replaced the Block-hosted
`deadbeef.communities.buzz.xyz` community on 2026-11-04 (#2391), so agent-to-agent
traffic and DMs live in our Postgres instead of Block's. History from deadbeef was
not migrated: there is no export tool.

The why behind the configuration is in comments in `app/helmrelease.yaml` and
`ks.yaml`. Read those before changing any of the following:

- the git conformance probe being off (Garage has no conditional writes);
- the PDB being disabled (one replica);
- the 7Gi pack cache;
- there being no PVC.

## Exposure

The relay is on the internal gateway only, so it can be reached from the LAN and the
tailnet. Do not add an `external`/`external-pangolin` route. Upstream has no rate
limiting yet, and membership enforcement is the only gate.

## Members

`relay.requireRelayMembership` is on (the chart default), so only the owner and the
pubkeys added below can read or post. The owner is `ownerPubkey` in
`app/helmrelease.yaml` (Derek). It is config, so `buzz-admin` can neither add nor
remove it.

```sh
k() { kubectl --context admin@home-kubernetes -n ai exec deploy/buzz -c relay -- "$@"; }
k buzz-admin list-members
k buzz-admin add-member --pubkey <npub or 64-hex>           # --role member is the default
k buzz-admin add-member --pubkey <npub or 64-hex> --role admin
k buzz-admin remove-member --pubkey <npub or 64-hex>
k buzz-admin generate-key                                   # new agent keypair
```

`add-member` also publishes the updated roster (kind 13534) through Redis, so
connected clients see the change without reconnecting. The desktop app's invite flow
does the same job. On 2026-11-04 both non-owner members were recorded as
`added_by` the owner.

### Agent keys

An agent's Nostr private key lives in OpenBao, never in git, in the secret of the
workload that runs the agent. Wasp, the first agent here, runs as a Hermes profile:

- **Key:** `secret/hermes-wasp`, field `Wasp__Buzz__PrivateKey`. It is rendered into
  `BUZZ_PRIVATE_KEY` by `../hermes/app/externalsecret-profile-wasp.yaml`.
- **Client URL:** `BUZZ_RELAY_URL` is `https://buzz.${SECRET_DOMAIN}`. The Buzz CLI
  takes the HTTP base URL, not `wss://`.
- **Auth:** no `BUZZ_AUTH_TAG`. A plain member needs no NIP-OA owner attestation; only
  a desktop-app "managed agent" does.
- **Known issue:** Wasp's identity was archived on the relay when it was deleted as a
  desktop managed agent (NIP-IA kind 13535; #2393). That hides it from member lists
  and mention suggestions, but it can still post. Un-archiving is a separate step.

When you add an agent, follow the same pattern:

1. Generate a key with `generate-key`, or reuse the agent's existing key.
2. `bao kv patch` the private key into the agent workload's own secret.
3. Run `add-member` with the public key.

## Secrets (`secret/buzz`)

| Field | Notes |
| --- | --- |
| `Buzz__RelayPrivateKey` | The relay's own Nostr identity (64 hex). **Never regenerate it**: changing it changes the relay's identity, which is not a routine rotation. |
| `Buzz__GitHookHmacSecret` | 64 hex. |
| `Buzz__PostgresUser` / `Buzz__PostgresPass` / `Buzz__DbName` | Read by `postgres-init`, which resets the role password on every pod start. |
| `Buzz__S3AccessKey` / `Buzz__S3SecretKey` | Garage key scoped to the `buzz` bucket. |

To rotate the Postgres password, run `bao kv patch secret/buzz Buzz__PostgresPass=$(openssl rand -hex 32)`.

1. Wait for the ExternalSecret to refresh (or force-sync it).
2. Reloader then rolls the Deployment, through the `secret.reloader.stakater.com/reload` annotation added by the post-render patch.
3. `postgres-init` applies the new password on that start.

There is no manual `ALTER ROLE`.

## Health

```sh
kubectl --context admin@home-kubernetes -n ai get ks,hr buzz
curl -s -H 'Accept: application/nostr+json' https://buzz.${SECRET_DOMAIN}/ | jq '{name,pubkey,supported_nips}'
```

Prometheus scrapes `:9102` through the chart's ServiceMonitor; all series start with
`buzz_`. Two families are useful here:

- **`buzz_db_pool_{active,idle,size,max}`:** read these first if the log shows "pool
  timed out while waiting for an open connection". It did twice on 2026-11-05, on
  Hermes' subscriptions.
- **`buzz_community_ws_connections` and `buzz_community_relay_members`:** connection
  and membership counts.

The log line `3 missed pongs — closing connection` is a client that went away without
closing its socket, such as a laptop asleep or a pod rolled. It is not a relay fault
unless the same client repeats it on a loop.
