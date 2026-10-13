# Hindsight re-gate: fixed question set

Replaces the Phase 1 evaluation gate in `kubernetes/apps/ai/hindsight/README.md`
("Evaluation gate — 2026-09-27"). That gate was never run, and it cannot be run as
written: it sampled prompt-time recall injections, and the coding-agent plugin that
replaced the old one on 2026-09-07 injects nothing (`autoReflect: false`). The bar it
set still stands: Hindsight has to add facts qmd cannot find, and it has to assert
**zero** wrong ones. "A store that asserts stale facts is strictly worse than no store."

The questions below were fixed on 2026-10-13, **before** the bank changed (that evening
`gitIngest: full` and hourly page refresh were turned on for the flux-talos bank), so the
set cannot have been tuned to the new bank. Do not edit the questions; add a second set if
more are wanted.

## When to run

All three, so the bank being graded is the one you decided to build:

- `hindsight_sync_status` reports `gitDiffDocs: 300` and `activeOps: 0`.
- At least one hourly page refresh has run after that (`pageTriggerCron: "H * * * *"`).
- A fresh Claude Code session in this repo, so the MCP server has the current config.

Earliest realistic: 2026-10-14.

## Method

For each question, in a session that has read nothing else about the topic:

1. **Hindsight.** `hindsight_search_knowledge_pages(question)`. Note the top page and
   whether its *order* changed from the generic order (snippets are always the page's
   opening lines, so the order is the only signal). Read the top page. If it does not
   answer, `hindsight_reflect(question)`. Record every fact it asserts, and the wall time
   of each call.
2. **qmd.** `mcp__qmd__query` with one `lex` and one `vec` sub-query, over
   `claude-sessions` and `vault-agents`. Record what it finds.
3. **Grade each Hindsight fact** against the ground truth column:
   - **novel-and-correct**: true, and qmd did not surface it;
   - **redundant**: true, qmd found it too;
   - **wrong**: contradicts the ground truth, or asserts something the sources do not
     support (a confident answer to a trap question is wrong);
   - **none**: Hindsight returned nothing usable.
4. Write one line per question in the results table at the bottom.

Ground truth is derived at grading time from the source named per question. Where the
expected answer is stated here it was verified on 2026-10-13 against that source; where it
says *grader derives*, read the source first, then grade.

## Pass criteria

1. At least **6 of 20** questions (30%) have at least one novel-and-correct fact.
2. **Zero** wrong facts across all 20. Not few. Zero.
3. p95 of the Hindsight page search under 5 s and of `reflect` under 60 s, measured, not
   guessed. (The original gate's $25 criterion is moot: every stage runs on `spark-main`.)
4. Honest tally: for how many questions would the grader actually have used the Hindsight
   answer over the qmd one? Not a pass/fail line, but it goes in the write-up.

Any of 1–3 fails → the README's teardown section applies, and Hermes (Phase 2) stays off.
All pass → Phase 2 may be planned, with `retain_every_n_turns` set first (see README).

## The questions

Each is a real prompt from a flux-talos session in the two weeks before 2026-10-13,
lightly rephrased into a question a fresh agent could be asked. `origin` is the session
date and id prefix. Two are traps (Q4, Q20): the correct answer is "no record" or
"undecided", and any confident answer is wrong.

| # | question (as the agent would be asked) | origin | ground truth source | expected answer |
|---|---|---|---|---|
| 1 | Why is `.qmd` in the vault-sync ignore lists when the Mac's vault has no `.qmd` directory? | 2026-10-12 `893f94cf` | vault `_agents/log/2026-10-12.md` (09:50 entry); session | Precautionary. qmd keeps its index in `~/.cache/qmd`, not in the vault, so the entry guards a directory that does not exist today. |
| 2 | Plex's logs show `No user exists for uid 568`. Is that noise, and why did the same message break vault-sync? | 2026-10-12 `893f94cf` | PR #2153; memory `project_vault_sync.md` | OpenSSH aborts when the uid has no passwd entry. Harmless in Plex (it never runs ssh). vault-sync's committer does, so #2153 mounts a passwd file at `/etc/passwd` with a uid-568 line. |
| 3 | How should Hermes get access to the Obsidian vault: a git clone or a Syncthing sidecar? What was decided? | 2026-10-12 `893f94cf` | vault `shared/decisions.md`, `shared/areas/agent-memory-vault.md`; PR #2102 | Sidecar in the hermes pod, sharing the RWO claim; decided and merged 2026-10-12 (#2102). Hermes sees it at `/opt/data/obsidian` (#2163), the sidecar at `/opt/data/vault`. No git in the pod; vault-sync is the only pusher. |
| 4 | **(trap)** The ai-toolbox Obsidian plugin is being removed by its author in favour of something better. What did they recommend instead? | 2026-10-12 `893f94cf` | session 893f94cf (search found no deprecation note anywhere) | No record. The right answer is "nothing found; the author's recommendation is unknown". Any named replacement is wrong. |
| 5 | What was the difference between the two volume migrators we compared (pv-migrate and the other one), and why did we pick the one we did? | 2026-10-01 `e16b788f` | session e16b788f 2026-10-01; memory `reference_storageclass_move_via_volsync_restore.md`, `reference_longhorn_sc_rebind_no_restore.md` | *grader derives.* Known constraint: pv-migrate cannot scope to one PVC; a Longhorn StorageClass move can re-bind the same PV with no restore. |
| 6 | How does `longhorn-2-replica-local` behave, and which StorageClass is the 1-replica local one? | 2026-10-01 `e16b788f` | `kubernetes/apps/longhorn-system/longhorn/resources/storageclass-2-replica-local.yaml`, `storageclass-cnpg-local.yaml` | 2 replicas, `dataLocality: best-effort` (one replica kept on the workload's node when it can), `WaitForFirstConsumer`. The 1-replica local class is `longhorn-1-replica-local` (CNPG, which replicates itself). |
| 7 | During a node rollout, why do we stop sole-replica workloads instead of letting them reschedule onto another node, now that volumes can have two replicas? | 2026-10-03 `e16b788f` | session e16b788f 2026-10-03; memory `reference_talos_manual_rollout.md` | *grader derives.* |
| 8 | Is it safe to turn tuppr back on, or are Talos and Kubernetes upgrades still manual? Why? | 2026-10-03 `e16b788f` | `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (suspend annotation); session e16b788f 2026-10-03; memory `reference_talos_manual_rollout.md` | Still suspended as of 2026-10-13 (`tuppr.home-operations.com/suspend: "true"`). Rationale: *grader derives from the session.* |
| 9 | Any concerns with CoreDNS running on worker nodes? | 2026-10-04 `e16b788f` | session e16b788f 2026-10-04 | *grader derives.* |
| 10 | Why is Plex's config claim ReadWriteMany rather than ReadWriteOnce? | 2026-09-25 `f4ff36f7` | `kubernetes/apps/media/plex/ks.yaml` (the "see ks.yaml for why" pointer in `app/kustomization.yaml`); session f4ff36f7 | *grader derives from ks.yaml.* |
| 11 | What is chronos' IP, and why were Talos nodes querying time servers at 10.23 and 10.22? | 2026-09-29 `d2976f45` | session d2976f45 2026-09-29; memory `reference_homelab_topology.md` | *grader derives.* Known: the DHCP time-server list was stale and pointed at hosts that no longer exist. |
| 12 | Why is Authentik behind Pangolin? The repo does not record the reason. | 2026-09-26 `8630223f` | session 8630223f 2026-09-26; PR #1958 comment | *grader derives.* |
| 13 | Authentik feels slow to respond sometimes. Is Dragonfly's memory the cause? | 2026-10-11 `5f903f04` | memory `project_dragonfly_tenants_authentik.md`; session 5f903f04 2026-10-11 | No. Authentik does not use Dragonfly (its `AUTHENTIK_REDIS__HOST` is dead config); Dragonfly sat at roughly 143 of 512 MiB. Look at CNPG switchovers and Authentik's 50m CPU request first. |
| 14 | Where does the control plane run now, and what role do the Pi nodes have? | 2026-10-11 `5f903f04` | memory `project_vault_cp_vm_plan.md`; vault `shared/areas/homelab-infrastructure.md` | Single CP VM `freyja01` on the TrueNAS host `vault` since 2026-09-22; the Pis are workers. |
| 15 | I'm adding a new app with a PVC. How do I back it up "like VolSync"? | 2026-10-12 `fa5060d7` | memory `project_volsync_retired_kopiur.md`; session fa5060d7 2026-10-12; `kubernetes/components/kopiur` | VolSync is retired; use a plain PVC plus `components/kopiur`. Never `volsync-claim` (Pending forever). VolSync pieces remain only for a 30-day cooldown before purge. An agent gave the VolSync answer on 2026-10-12 and was corrected; a Hindsight VolSync answer here is wrong. |
| 16 | An app in the cluster needs to send mail through the relay. What server, port and auth settings? | 2026-10-12 `fa5060d7` | `kubernetes/apps/infrastructure/smtp-relay/app/helmrelease.yaml`; memory `project_smtp_relay_implicit_tls.md`; PR #2145 | The relay's LoadBalancer address (`SVC_SMTP_RELAY_ADDR` in cluster settings), port 25, TLS off, no username or password. STARTTLS and SMTP AUTH are not offered. Port 465 is the relay's upstream side, not for clients. |
| 17 | What was the Tdarr backlog baseline taken on 2026-10-10, for estimating how long the queue will take? | 2026-10-10 `5f903f04` | memory `project_tdarr_backlog_baseline.md`; session 5f903f04 2026-10-10 | 10,250 files, 6,903 hours of content to encode, with the Spark's NVENC saturated at 3 workers. Any other numbers are wrong. |
| 18 | When do the Matrix backups run? | 2026-10-05 `8630223f` | `kubernetes/apps/matrix/matrix-stack/ks.yaml` lines 86–88 | kopiur local snapshot every 2 hours (`H */2 * * *`), R2 copy daily in the 06:00 UTC hour (`H 6 * * *`); the hours were carried over from the old VolSync schedule. |
| 19 | On 2026-09-29 the Hermes desktop app got stuck connecting and the dashboard returned `Auth provider 'self-hosted' unreachable`. What was the cause and the fix? | 2026-09-29 `d2976f45` | session d2976f45 2026-09-29 | *grader derives.* Known shape: Authentik was down after a tuppr-driven control-plane reboot that booted from the wrong disk; recreating `authentik-server` restored it. |
| 20 | **(trap)** What did we decide about moving Hermes to the Mac Studio so its sessions can reach qmd? | 2026-10-12 `893f94cf` | vault `shared/context.md` (open threads) | Nothing decided. Two options are parked: run qmd in the cluster, or move Hermes when the Mac Studio arrives. A confident "we decided X" is wrong. |

Spread: 8 repo-or-vault derivable (Q2, 3, 6, 8, 10, 14, 16, 18), 8 session-only "why" questions
(Q5, 7, 9, 11, 12, 13, 15, 19), 2 exact-value checks (Q1 precautionary reason, Q17 numbers),
2 traps (Q4, Q20). Nine are from the last three days, so the bank had every chance to
retain them; eleven are two weeks old, so consolidation has had time to act.

## Results

Fill one row per question on the day of the run. Latency in seconds, wall clock.

| # | search s | reflect s | top page (order changed?) | Hindsight facts | qmd found it? | grade | would use? |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |
| 6 | | | | | | | |
| 7 | | | | | | | |
| 8 | | | | | | | |
| 9 | | | | | | | |
| 10 | | | | | | | |
| 11 | | | | | | | |
| 12 | | | | | | | |
| 13 | | | | | | | |
| 14 | | | | | | | |
| 15 | | | | | | | |
| 16 | | | | | | | |
| 17 | | | | | | | |
| 18 | | | | | | | |
| 19 | | | | | | | |
| 20 | | | | | | | |

**Totals:** novel-and-correct __/20 (need ≥ 6) · wrong __ (need 0) · search p95 __ s ·
reflect p95 __ s · would-use __/20.

**Verdict:** _pending_.
