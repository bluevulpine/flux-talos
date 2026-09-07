# Hindsight — agent memory

Long-term memory for the cluster's agents. Design and reasoning:
`docs/superpowers/specs/2026-09-06-hindsight-agent-memory-design.md`.
Implementation plan: `docs/superpowers/plans/2026-09-06-hindsight-phase1.md`.

**Phase 1 is an evaluation, not a migration.** `MEMORY.md` and qmd stay authoritative
throughout. Hindsight is supplemental — a *session-memory* layer, where qmd is a
*corpus-search* layer. It cannot replace qmd: different corpora (qmd indexes 1,429 docs
across eight collections; Hindsight knows only what has been retained from agent sessions),
different failure modes (qmd's index is rebuildable from files you own; Hindsight's store is
derived, lossy, and not reconstructible from its own contents), different cost (qmd is free
to query).

## Before first deploy — create the OpenBao key

The ExternalSecret will not sync until `hindsight` exists in OpenBao with all four fields.

```bash
bao kv put <mount>/hindsight \
  Hindsight__Postgres__User=hindsight \
  Hindsight__Postgres__Password='<generate: [A-Za-z0-9] ONLY>' \
  Hindsight__Llm__ApiKey='<Anthropic Console API key, sk-ant-...>' \
  Hindsight__TenantApiKey='<generate: long random>'
```

`Postgres__SuperPassword` is **not** set here — it is pulled from the shared `cloudnative-pg`
key by a second `dataFrom.extract`, so the superuser password stays in exactly one place.

**`Hindsight__Llm__ApiKey` is an Anthropic *Console* key, not your Max plan.** A Claude
subscription is not API access — the `anthropic` provider wants a metered Console key, billed
separately. This is a deliberate trade: the two providers that would have reused an existing
subscription both need interactive OAuth with a rotating, self-rewriting token store
(`~/.hermes/auth.json` for `nous`, the Claude Code credential store for `claude-code`), which
is not something an unattended pod can hold. See the LLM comment block in `app/helmrelease.yaml`.

**The password character set is not a style preference.** Hindsight takes a DSN rather than
discrete host/user/pass fields — the only Postgres app here that does — so an `@`, `/`, `:`
or `#` parses wrong and presents as a bad credential rather than a malformed URL.

**`Hindsight__TenantApiKey` is a cluster-admin-equivalent credential.** One key grants full
read *and write* across every bank, with no per-consumer isolation: `ApiKeyTenantExtension`
compares against one expected key and resolves every authenticated request to one hardcoded
schema, so banks are a naming convention, not a boundary. Write is the dangerous half —
recalled memories are injected directly into the prompt of a Claude Code session holding
`kubectl` against this cluster, so anyone with the key can plant a memory and have it
delivered to a future session as trusted prior context. That is a persistent
prompt-injection channel with a multi-week fuse. Rotate it on that footing.

## First-deploy checks

Two things are expected to need confirming on the first running pod:

```bash
# 1. pgvector actually got created (02-init-vector is the container that does it;
#    the app role cannot, because pgvector is not a "trusted" extension)
kubectl -n ai logs deploy/hindsight -c 02-init-vector

# 2. the backlog metric names the PrometheusRule alerts on.
#    NOTE the image ships neither wget nor curl -- use its own Python.
kubectl -n ai exec deploy/hindsight -c api -- python -c \
  "import urllib.request; print(urllib.request.urlopen(
   'http://localhost:8888/metrics').read().decode())" | grep ^hindsight_
```

Verified on 2026-09-07: `hindsight_consolidation_backlog` and `hindsight_consolidation_failed`
are both present. **`hindsight_async_operations` is absent until the first retain** and that is
correct, not a bug -- it is an observable gauge over `_async_ops_counts`, which yields no
observations while empty, so no series is emitted. Its name follows the same braced-unit rule
as the two confirmed ones (`{operations}` takes no suffix, unlike unbraced units such as
`hindsight_llm_tokens_input_tokens_total`).

## Consumer — Claude Code (the only Phase 1 consumer)

```
claude plugin marketplace add vectorize-io/hindsight
claude plugin install hindsight-memory
```

`~/.hindsight/claude-code.json` (note: plaintext on the laptop — not SOPS, not OpenBao):

```json
{
  "hindsightApiUrl": "https://hindsight.<domain>",
  "hindsightApiToken": "<Hindsight__TenantApiKey>",
  "dynamicBankId": true,
  "dynamicBankGranularity": ["agent", "project"],
  "retainToolCalls": false,
  "requestTimeoutSeconds": 3
}
```

Both non-default lines are load-bearing:

- **`retainToolCalls: false`** is already the plugin default, but set it explicitly. It is
  the single control that keeps `sops -d` output, `kubectl get secret -o yaml`, and bash
  results from ever being sent to Anthropic. There is no redaction, sanitisation, or pattern
  filter anywhere in `retain.py` — `retainMission` is a *prompt instruction*, and the raw
  text is sent in full regardless of what gets extracted. The only pre-send control is not
  retaining at all. **Revisit the whole sensitivity analysis if this is ever turned on.**
- **`requestTimeoutSeconds: 3`** bounds the one hook that degrades badly. `SessionStart`
  (5 s, `sys.exit(0)` on error) and `Stop` (`async: true`, 15 s) are fine when Hindsight is
  down. `UserPromptSubmit` is **not** async and defaults to a 10 s per-call timeout, so a
  down Hindsight would add ~10 s of silent latency to *every prompt*, indefinitely, with the
  error only on stderr.

## Evaluation gate — 2026-09-27, no extensions

Sample the last 20 `UserPromptSubmit` prompts that triggered a recall injection. Run each
query through `mcp__qmd__deep_search` over `claude-sessions`. Classify every
Hindsight-recalled fact as **novel-and-correct**, **redundant** (qmd found it too), or
**wrong**.

Proceed to Phase 2 (Hermes) only if all three hold:

1. ≥30% of recalled facts are novel-and-correct.
2. **Zero** confidently-wrong facts. Not "few" — zero.
3. Actual spend over the window, read from `/llm-requests` (which records token usage per
   call, including failed calls) rather than estimated, is under **$25**.

Any one fails → tear down per below. No "let's give it another month."

The zero-wrong bar is what makes this a test rather than a formality, and it is the bar
Hindsight is most likely to fail. Vectorize themselves note it has **no fact-validity
windows** — no concept of a fact ceasing to be true. This repo's memory set is full of
entries that expire ("cross-seed v7 PENDING", "tuppr upgrade gate RESOLVED", "BWSM migration
complete"). A store that asserts stale facts is strictly worse than no store, because recall
launders them into the prompt as trusted prior context.

Also measure during the window, since both are currently unmeasured guesses:

- **p95 recall latency.** Upstream gives 100–600 ms and names the CPU reranker as the
  bottleneck. If it drifts, moving to TEI is one env var
  (`HINDSIGHT_API_RERANKER_PROVIDER: tei`).
- **Drain cost.** Estimated 3–6 minutes of unavailability per node drain, per HelmRelease
  upgrade, and per Talos upgrade cycle.

## Not in Phase 1

Hermes (Phase 2, confirmed in scope), Buzz agents (Phase 3), Home Assistant (Phase 4).
Hermes is deferred deliberately so there is a clean single-consumer cost baseline. When it
is enabled, **set `retain_every_n_turns` first**: it defaults to `1` in Hermes' plugin
versus `10` in the Claude Code plugin, so at stock settings the continuously-running
consumer retains 10× more often per turn. It is set in
`$HERMES_HOME/hindsight/config.json`, not through the `hermes memory setup` wizard, whose
schema exposes only five fields.

Home Assistant needs a **second Hindsight instance, not a second bank** — with one key and
one schema, banks are a naming convention, not a boundary.

Also not taken, deliberately: external gateway exposure (internal only during Phase 1; if it
is ever wanted it needs OAuth via Authentik, not a shared bearer token), the provider Batch API
(halves cost but turns retain into a minutes-to-hours SLA, and the setting is server-wide so
it cannot be scoped to one consumer — the objection is provider-independent), and OpenCode Zen free models (read the terms first —
free tiers commonly train on submitted data, which would undo the retention reasoning).

## Teardown

Ordering matters. ESO's finalizer deletes the Secret when the ExternalSecret goes, even
under an Orphan policy, so do the database work **first**, while credentials still exist.

```bash
# 0. FIRST, while hindsight-secret still exists:
#    pg_dump -U postgres -Fc hindsight > hindsight-final.dump   # only if keeping anything
#    DROP DATABASE hindsight; DROP ROLE hindsight;              # as superuser
# 1. verify nothing depends on it, then remove the tree:
#    grep -rl hindsight kubernetes/apps --include=ks.yaml
#    rm -rf kubernetes/apps/ai/hindsight kubernetes/apps/ai
# 2. the namespace carries prune: disabled — kubectl delete ns ai BY HAND
# 3. bao kv delete .../hindsight   (and rotate anything the key touched)
# 4. laptop: claude plugin uninstall hindsight-memory && rm -rf ~/.hindsight
#    and remove the hook entries from ~/.claude/settings.json
# 5. NOT reversible: every transcript already sent to Anthropic.
```

Also revert the two out-of-tree edits if nothing else has adopted them: the `ai` entry in
`kubernetes/apps/identity/authentik/app/referencegrant.yaml`, and `POSTGRES_HOST_RO` in
`kubernetes/components/common/cluster-config/cluster-settings.yaml`.

**CNPG PITR cannot restore `hindsight` alone** — it restores the whole cluster to a point in
time, dragging all ~34 databases with it, and base backups are weekly. This is the one
database here where the shared backup is effectively unusable for a targeted rollback.
Deleting the Kustomization un-deploys a pod; it does not un-send the data.

## Known gap, pre-existing and not introduced here

`cluster18/prometheusrule.yaml` has six alerts and **none** watches connection count against
`max_connections` (`BackendsWaiting > 300` is lock waits, not slot exhaustion). Hindsight
caps its own pool at 20 + 10 so it cannot be the app that exhausts it, but the cluster-wide
gap should be closed regardless:

```yaml
- alert: CNPGConnectionsNearLimit
  expr: sum(cnpg_backends_total{namespace="database"}) / 400 > 0.75
  for: 10m
```

Deliberately not added here — it edits a file outside this app's tree and belongs to the
database app, not to Hindsight.
