# Runbook: rotating the Talos and Kubernetes PKI

**Audience:** the operator (Derek) or an agent working with him.
**When:** the secrets bundle (`talos/secrets.sops.yaml`) or a rendered machine config leaks,
or a CA nears expiry. Written after the 2026-11-05/06 rotation that followed the public leak
in commit `60dc0f1fb` (rendered talhelper configs committed in plaintext).

Single control plane (freyja01, VIP 10.0.10.30), single etcd member, 7 workers. Every
step below was run for real on Talos v1.13.11 / Kubernetes 1.36.2.

## Ground rules

- Never write the decrypted bundle to disk. Update it with
  `sops set --value-stdin talos/secrets.sops.yaml '["certs"]["k8s"]'` (JSON value on stdin).
  `topf render` only into a `mktemp -d`, then delete it.
- Print hashes, names and lengths of secret values, never the values or fragments.
- Use a `talosctl` client of the **cluster's** version for `rotate-ca` and `gen secrets`;
  a newer client generates material in formats the older machined may reject.
- The diff gate for every apply is `topf --nodes-filter '^<host>$' apply --dry-run`.
  Count changed lines with `grep -cE '^ {5}[-+] '`: a looser pattern counts YAML list
  context lines and miscounts. topf refuses a node whose static pods aren't ready yet:
  wait, don't force.
- Keep one copy of the bundle as the source of truth (the checkout you apply from); copy it
  to the branch only after the phase that changed it shows diff 0 on every node it touches
  (steps 2, 3 and 8 each commit).

## What each field costs

| Bundle field | Machine config | Apply | Notes |
|---|---|---|---|
| `certs.os` | `machine.ca` | `talosctl rotate-ca --talos=true --kubernetes=false` | Old and new CA trusted during the switch; regenerate `talos/talosconfig` after. |
| `certs.k8s` | `cluster.ca` | `talosctl rotate-ca --talos=false --kubernetes=true` | Same two-phase switch. In-cluster clients that loaded the old CA get x509 errors until restarted. |
| `certs.k8saggregator`, `certs.etcd` | `cluster.aggregatorCA`, `cluster.etcd.ca` | control plane, **reboot** | Single etcd member, so no rolling; ~3-5 min API outage. |
| `certs.k8sserviceaccount` | `cluster.serviceAccount.key` | control plane, with the reboot above | **Hard cutover, no grace period**: every projected SA token is invalid until its pod restarts. |
| `trustdinfo.token` | `machine.token` | **every node, reboot** | trustd signs any CSR that presents it. The only field that forces worker reboots. |
| `secrets.bootstraptoken`, `cluster.id`, `cluster.secret` | `cluster.token`, `cluster.id`, `cluster.secret` | no reboot | Talos leaves the old bootstrap-token Secret in `kube-system`: delete it. |
| `secrets.secretboxencryptionsecret` | `cluster.secretboxEncryptionSecret` | **not rotatable today** | Talos has no multi-key encryption config, so a new key makes every existing Secret in etcd unreadable. Deferred 2026-11-05; revisit when Talos ships multi-key support. |

## Order

1. **Before:** etcd snapshot (talos-backup job). Check OpenBao's `auth/kubernetes/config`
   doesn't pin `kubernetes_ca_cert` or a reviewer JWT; if it does, rewrite it after step 5
   (the new k8s CA in step 4 stales a pinned CA, the SA key in step 5 a pinned JWT),
   before restarting clients in step 6.
2. **Talos API CA** (`rotate-ca --talos=true`), regenerate `talos/talosconfig` (gitignored,
   holds the admin key: never commit it). Commit `certs.os` in the bundle once this phase's
   diff is 0.
3. **Bootstrap token, cluster id/secret:** apply with `--mode no-reboot` to all nodes, then commit the bundle.
4. **Kubernetes CA** (`rotate-ca --kubernetes=true`, explicit `--nodes`). Capture the new
   CA into the bundle and write a new kubeconfig (`talosctl kubeconfig`) to use for the rest
   of the window.
5. **Aggregator CA, etcd CA, SA key, trustd token** into the bundle. freyja01's dry-run
   must show exactly those 4 changes; apply it with `--mode reboot`. Check etcd, `/readyz`,
   all nodes Ready.
6. **Restart API clients at once:** cilium (agent, operator, envoy), coredns, kube-system
   controllers (csi-nfs, nfd, metrics-server, snapshot-controller, spegel), longhorn-system
   (manager, CSI, driver-deployer), flux-system, external-secrets, cert-manager,
   cnpg-system, tailscale, tuppr, the ARC controller. OpenBao: one pod at a time, standby
   first (see `openbao-statefulset-roll.md`). Force one ExternalSecret sync to prove ESO.
7. **Workers, one at a time:** cordon, drain, `topf apply --mode reboot`, dry-run diff 0,
   uncordon, Ready. Gate each node on OpenBao 3/3 unsealed with 1 active and on no attached
   Longhorn volume unhealthy. Before the node holding the CNPG primary,
   `kubectl cnpg promote` a replica elsewhere.
8. **Sweep:** dry-run diff 0 on all nodes; no `x509`/`Unauthorized` in flux, ESO and
   cert-manager logs; Flux and ExternalSecrets all Ready. Commit the bundle.
9. **Credentials outside the cluster:** regenerate every kubeconfig and talosconfig holder
   (Mac `~/.kube/config`, the repo `kubeconfig`, anything on the NAS) and delete stale
   copies and any plaintext scratch (the `rotate-ca` output holds the new CA key).
10. **Verify:** hash-compare every secret leaf of every node's live `machineconfig`
    (including `acceptedCAs`) against the leaked values. Only the secretbox key may match.

## Traps met in 2026-11

- **Stale OpenBao `openbao-active` label.** After the SA key cutover the service-registration
  label PATCH fails with the old token, so a standby can still carry `openbao-active=true`.
  Check `bao status` before trusting the label.
- **The Mac's API route rides the cluster.** The Mac reaches 10.0.10.30 through Tailscale /32
  routes from the in-cluster `ts-exit-node` Connector. Draining the node it runs on drops
  API access for ~30 s: retry the drain instead of treating it as a failure.
- **Longhorn drain blockers.** The manager log names the blocker:
  `removing <node> PDB is blocked: ...`. Met in order:
  - attached single-replica volumes: give them a second replica for the window
    (`numberOfReplicas: 2`), set back to 1 afterwards;
  - orphaned `snapshot-controller-*` attachment tickets keeping detached volumes attached:
    remove the ticket when no Longhorn Snapshot matches its uid or name;
  - engine instances for deleted volumes: delete the `orphans.longhorn.io` record. With no
    record, confirm only the instance-manager is left and no attached volume has its only
    running replica on the node, then skip the drain;
  - detached single-replica volumes: `nodeDrainPolicy: allow-if-replica-is-stopped`
    (permanent since 2026-11-06; never `always-allow`);
  - offline-rebuild (`volume-rebuilding-controller`) tickets holding volumes attached on the
    node with their only healthy replica: wait for the rebuild. Raising
    `concurrent-replica-rebuild-per-node-limit` from 2 to 4 for the window cleared the queue
    quickly; set it back after.
- **Cold image pulls.** A rescheduled pod whose image only one draining node had cached
  pulls from upstream (Plex: ~9 min from ghcr). Spegel can't help while that node is down.
  It also exposed satisfactory's dead `ghcr.io/wolveix` image (account renamed upstream).
