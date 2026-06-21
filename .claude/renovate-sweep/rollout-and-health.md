# Renovate sweep — rollout & health

How to check a workload's health before touching it, monitor the rollout after merge,
and tell healthy-in-progress states and known baselines apart from real regressions.

## Pre-merge health check

Before merging any PR, confirm the target is currently healthy:

```
kubectl get helmrelease -n <ns> <app>          # READY=True, last upgrade succeeded
kubectl get pods -n <ns> | grep <app>          # desired replicas Running/Ready
```

For **stateful / secret / storage** workloads this is mandatory — a rollout restarts
pods, so you must know the starting state and the restart implications:

- **OpenBao (secrets backend, HA StatefulSet):** uses **static auto-unseal** (key from
  a SOPS-mounted Secret), so a rolling restart auto-unseals — safe. A *chart patch* that
  doesn't change the pod template won't even restart pods. Verify openbao-0/1/2 all 1/1
  before/after.
- **CloudNativePG / postgres16:** the operator (`cloudnative-pg`) bump rolls only the
  operator pod, not the DB. `postgres16-2/3/4` should stay Running; a single replica
  briefly `Pending` can be a pre-existing baseline — compare before/after, don't assume
  the bump caused it.
- **Longhorn:** do NOT bump in a sweep (no downgrade; cluster-wide engine roll).
- **Dragonfly:** see the dedicated section below — the operator has historically been
  silently degraded.

## Monitoring a rollout to steady state

1. Reconcile source + the affected HR/KS (see repo-runbook).
2. Watch the new pod reach Ready and the HR report success:
   ```
   kubectl rollout status deploy/<name> -n <ns> --timeout=120s
   kubectl get helmrelease <app> -n <ns>
   ```
3. For StatefulSets / operator-driven rollouts, watch the CR/phase and that each pod
   rolls to the new image and rejoins (don't just check "Running" — check role/topology
   where the operator assigns one).

## Healthy in-progress vs real failure

Normal, transient — keep waiting:
- `ContainerCreating`, `PodInitializing`, `Pending` (briefly, during scheduling).
- `Multi-Attach error` while an RWO/Longhorn volume moves during a `Recreate` rollout.
- DaemonSet/Deployment rolling one pod at a time.

Real problems — investigate:
- `CrashLoopBackOff` with a climbing restart count and an error in `kubectl logs`.
- `CreateContainerConfigError` (missing Secret/ConfigMap reference).
- A new pod stuck not-Ready well past its probe timings.

Harmless leftovers — note, don't chase:
- Old `Error` / `ContainerStatusUnknown` ghost pods left after a **node blip** when a
  healthy replacement is already Running elsewhere. Pattern seen: a batch of such pods
  all on one node (e.g. **brokkr03**), all the same age, each with a Running replica on
  another node. Confirm `kubectl get nodes` shows the node Ready again; the ghosts are
  dead pods not yet garbage-collected. Safe to `kubectl delete pod` as hygiene.

## Cluster-wide not-ready sweep

```
kubectl get pods -A | awk 'NR==1 || ($4!="Running" && $4!="Completed")'
```
Then separate: (a) caused by your merge, (b) pre-existing baseline, (c) unrelated
ghosts. Only (a) blocks; report (b)/(c).

## Known pre-existing baselines (not caused by sweeps)

These have appeared as not-ready without being your fault — verify they're unchanged,
don't attribute them to a bump:
- A CNPG `postgres16` replica occasionally `Pending`.
- `dev-shell-0` `Pending`.
- Cronjob failures: `kometa`, `unifi-phantom-clients-cleanup`
  (`CreateContainerConfigError` for days = a real missing-secret/config bug worth a
  separate fix), and other media cronjobs.
- `homebox` pinned to an older image digest because the newer build mandates
  `HBOX_AUTH_API_KEY_PEPPER` (needs an OpenBao secret first).

## Dragonfly operator (special case)

The dragonfly-operator is installed via the app-template chart, so it has historically
hit two latent misconfigs that make it **report the CR `Ready` while silently NOT
rolling** the StatefulSet (data pods stuck versions behind git):

1. **RBAC gaps** — needs `configmaps` (`""`) and `poddisruptionbudgets` (`policy`),
   full verbs. Missing perms crashloop the informer (1400+ restarts).
2. **NetworkPolicy label** — the operator-generated NetworkPolicy admits the admin port
   **9999** only from pods labelled `control-plane=controller-manager`. The app-template
   labels pods `app.kubernetes.io/name=dragonfly-operator`, so the operator can't reach
   9999 to verify readiness → roll stalls with an orphaned (role-less) replica. Fix:
   add `control-plane: controller-manager` to the operator `pod.labels`.

Symptoms to watch when bumping dragonfly: pod image lagging git; CR `RollingUpdate`
that never finishes; operator log `dial tcp <ip>:9999: i/o timeout` or
`poddisruptionbudgets ... is forbidden`. After fixing RBAC/labels, `kubectl rollout
restart deploy/dragonfly-operator -n database` to force the informer to re-sync; it then
rolls one replica at a time with a master failover, ending `Ready` with all pods on the
new image. (Both fixes landed in PRs #1390 / #1391.)
