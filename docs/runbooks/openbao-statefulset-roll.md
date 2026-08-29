# Runbook: OpenBao StatefulSet roll — recreating pods by hand after a chart or image bump

**Alert:** `KubeStatefulSetUpdateNotRolledOut` (severity `warning`, from kube-state-metrics)
**Fires when:** the `openbao` StatefulSet's `currentRevision != updateRevision` **and** `replicas != replicas_updated`.

This procedure runs against the cluster's secrets backend. If it goes wrong, every ExternalSecret stops resolving. Nothing here is dangerous when done in order — but the order is the whole runbook. Read [the CoreDNS failure mode](#step-3--verify-peer-dns-before-you-call-it-done) before your first roll; it has caused a real outage.

## Root cause

Nothing is broken. The `openbao` StatefulSet runs `updateStrategy: OnDelete`, so Helm and Flux update the pod template but Kubernetes **never recreates the pods itself**. An operator has to delete them. The alert is the expected consequence of every openbao chart or image bump, and the fix is to perform the roll deliberately, in an order that protects Raft quorum and leadership.

`OnDelete` is a choice, not an oversight. `RollingUpdate` would evict the active leader on the controller's schedule; `OnDelete` keeps failover under human control, so leadership moves when you decide it moves.

**Subject:** `openbao` StatefulSet, namespace `openbao`, 3 replicas, Raft HA storage, static auto-unseal. There is no manual unseal step anywhere in this runbook.

## Diagnose

Find out what the StatefulSet wants, what it has, and who currently leads:

```bash
# What the STS wants vs what it has
kubectl -n openbao get sts openbao -o jsonpath='{.status}' | jq

# Which pod is on which revision, and which one is the leader
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao \
  -o custom-columns='NAME:.metadata.name,REV:.metadata.labels.controller-revision-hash,ACTIVE:.metadata.labels.openbao-active,SEALED:.metadata.labels.openbao-sealed'
```

The pod carrying `openbao-active=true` is the Raft leader. Any pod whose `controller-revision-hash` differs from the STS `updateRevision` is stale and needs rolling.

Write down the answers before you touch anything — the roll order depends on them. Not every alert means all three pods are stale; standbys sometimes roll themselves via node reschedules, leaving a single stale pod to delete. When that single stale pod is the *leader*, the whole roll is one deletion (skip to Step 2).

## Pre-flight

### If you just merged a Renovate PR, land the change first

Merging does not update the StatefulSet — Flux has to reconcile before the new pod template exists. Rolling pods before that just recreates them on the *old* revision and the alert stays. Force it:

```bash
flux reconcile source git home-kubernetes -n flux-system
flux reconcile kustomization openbao -n openbao --timeout=5m
```

Two names that are easy to get wrong here: the GitRepository is **`home-kubernetes`**, not `flux-system` (there is also a `flux-talos-ssh` source pointing at the same repo, which lags), and the Kustomization lives in namespace **`openbao`**, not `flux-system`.

Then confirm the template actually changed before rolling anything:

```bash
kubectl -n openbao get helmrelease openbao \
  -o jsonpath='{.spec.chart.spec.version}{"\n"}{.status.conditions[0].message}{"\n"}'
kubectl -n openbao get sts openbao \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}chart={.spec.template.metadata.labels.helm\.sh/chart}{"\n"}'
```

> **Normal, do not panic:** immediately after a merge, `flux get kustomizations -A` will show a long list of apps not-ready with `dependency 'external-secrets/external-secrets-openbao-store' is not ready` or `revision is not up to date`. That is the dependency graph re-reconciling to the new commit, not breakage. It clears on its own within a few minutes.

**Which PR needs a roll:** the **chart** bump (`helmrelease.yaml`) is what changes the server image and requires this procedure. A bump to `snapshot-cronjob.yaml` only changes the backup CronJob's image and needs no roll at all.

### Gates — all must pass before you delete anything

```bash
kubectl -n openbao get helmrelease openbao -o jsonpath='{.status.conditions[0]}'   # want Ready=True
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide                        # note CoreDNS uptime — see Step 3
for p in openbao-0 openbao-1 openbao-2; do
  kubectl -n openbao exec $p -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao status
done
```

Require:

- HelmRelease `Ready=True` — otherwise you'd be rolling pods onto a template Flux hasn't finished reconciling.
- All three `Sealed: false`.
- All three Raft `Committed Index` values identical — a lagging peer is a peer that can't safely take over. (They advance constantly; you want them tracking together, not frozen at one number.)
- Exactly one `HA Mode: active`.

Also note how long CoreDNS has been up. Recently-restarted CoreDNS is the single biggest risk factor in this procedure; see Step 3.

## Step 1 — Roll the standbys, one at a time

**Never delete two pods at once.** A 3-node Raft cluster tolerates losing exactly one member. Lose two and you lose quorum, and the entire secrets backend goes down with it.

```bash
kubectl -n openbao delete pod <standby>
kubectl -n openbao wait --for=condition=Ready pod/<standby> --timeout=300s
```

After each pod, confirm all four before moving to the next one:

- it came back on the new `controller-revision-hash`
- `RESTARTS: 0`
- `Sealed: false`
- its Raft `Committed Index` has caught up to its peers

A pod that is `Ready` but still catching up on Raft is not yet a safe peer to lose the next one against. Wait for the index.

Skip any standby already on `updateRevision` — it has nothing to roll.

## Step 2 — Roll the active pod last

Delete the leader only once every standby is on the new revision:

```bash
kubectl -n openbao delete pod <active>
kubectl -n openbao wait --for=condition=Ready pod/<active> --timeout=300s
```

Deleting the leader forces an election, and an already-updated standby wins it **by definition** — because by this point every standby is already on the new revision. That is the entire trick: standbys-first *is* the mechanism that puts leadership where you want it.

> If `kubectl wait` returns `Error from server (NotFound): pods "openbao-N" not found`, that is a race, not a failure — the StatefulSet controller hadn't recreated the pod yet. Re-run the same `wait`.

**There is no way to hand leadership to a chosen node.** Stated plainly because people go looking for one:

- `bao operator raft promote` / `demote` control **voter vs non-voter** status. Nothing to do with leadership.
- `bao operator step-down` makes the *incumbent* resign and triggers an election, but you cannot pick the winner.
- There is no `transfer-leader` subcommand in OpenBao.

## Step 3 — Verify peer DNS before you call it done

> ⚠️ **This is the failure mode that caused a real outage on 2026-07-31.** It is the most important thing in this runbook.

Rolled pods come back with **new IPs**. On that occasion CoreDNS was still serving **stale A records**, so Raft peers kept dialing the pre-roll IPs on cluster port `8201`. Elections timed out (`requestVote RPC i/o timeout`, term climbing), and **all three pods sat at `HA Mode: standby` with no active leader — a full secrets outage.**

The trap is that the Kubernetes EndpointSlice was **correct the entire time**. Only in-pod DNS resolution was wrong, so every check that looked at Endpoints reported healthy. The trigger was CoreDNS having itself rolled about 50 minutes earlier, leaving its endpoint watch out of sync.

Compare what a pod *resolves* against what the pods' IPs actually *are*:

```bash
# What the pods' addresses really are
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao \
  -o custom-columns='NAME:.metadata.name,IP:.status.podIP'

# What a peer thinks they are (run from any pod, check all three names)
for t in openbao-0 openbao-1 openbao-2; do
  printf '%s -> ' "$t"
  kubectl -n openbao exec openbao-1 -c openbao -- getent hosts "$t.openbao-internal" | awk '{print $1}'
done
```

If they disagree:

```bash
kubectl -n kube-system rollout restart deployment/coredns
```

Raft is already retrying elections continuously, so a leader appears within seconds of DNS returning correct addresses. No further action is needed on the openbao side.

Risk is highest when you roll all three pods and when CoreDNS has restarted recently. Check this every time regardless — it costs one command and it is the difference between a clean roll and an outage you diagnose from the wrong layer. It is also worth running *between* Step 1 and Step 2, so you find stale DNS while you still have a healthy leader rather than after you've given it up.

## Known quirk — `currentRevision` never advances

Under `OnDelete`, the controller **never updates `currentRevision`**. After a completely successful roll, the STS still reports `currentRevision` as an old hash while `updateRevision` is the new one, and it stays that way permanently.

Do not chase it. The alert clears anyway, because its other factor (`replicas != replicas_updated`) stops matching once every pod is updated. **The field to trust is `updatedReplicas == replicas`.**

## Verification

- [ ] All pods on `updateRevision`, `RESTARTS: 0`
- [ ] `updatedReplicas == replicas == readyReplicas`
- [ ] All three `Sealed: false` (static auto-unseal — there is never a manual unseal step)
- [ ] All three report the expected new `Version` in `bao status`
- [ ] Raft `Committed Index` identical across all three
- [ ] Exactly one `active`, two `standby`
- [ ] In-pod DNS resolves each peer's **current** IP
- [ ] End-to-end: `kubectl get clustersecretstore openbao` shows *store validated*, and no ExternalSecret is not-ready
- [ ] `KubeStatefulSetUpdateNotRolledOut` no longer present in Prometheus

```bash
# the two end-to-end checks worth running every time
kubectl get clustersecretstore openbao
kubectl get externalsecrets -A | grep -v ' True ' | head
```

The ExternalSecret check is the one that proves the roll worked from the consumer's side rather than from openbao's own opinion of itself. Don't skip it.

## Related

- `kubernetes/apps/openbao/RECOVERY.md` — disaster recovery: snapshot restore and seal-key rotation. Different document, different problem. If you are here because the roll went wrong and Raft won't recover, that is where to go next.
