# Kia collector: OTP re-auth after rmtoken death

**Alerts:** `KiaCollectorJobFailed`, `KiaCollectorStale`
**Symptom:** every `kia-collector-cached` run fails within ~20s; vehicle telemetry
stops updating in InfluxDB / the EV9 Grafana dashboard.
**Fix time:** ~2 minutes, but requires a human with access to the account's OTP.

## 1. Do not start with `kubectl logs`

It returns nothing, and the emptiness is meaningless.

The CronJob pods run `restartPolicy: OnFailure`, so `backoffLimit` counts
**container restarts inside a single pod**, not pod failures. The container
crash-loops to the limit in ~20 seconds, the job controller marks the Job
`BackoffLimitExceeded` and **deletes the pod**, taking its logs with it. You will
see `failed: 1` against `backoffLimit: 2`, which looks wrong but is expected.

Every failure mode therefore looks identical and silent after the fact. A 2026-08-09
investigation used "these pods emitted no log output at all" to rule *out* the
token-death path; that inference was invalid, and the note in `cronjob.yaml` has
since been corrected.

## 2. Read the tombstone in OpenBao

`collector.py:clear_token()` cannot delete the KV entry (the ServiceAccount policy
grants create/update but not delete), so on rmtoken death it **overwrites** the
secret with a tombstone. Reading it is safe — the token is blank by then.

```bash
BAO_ADDR=http://openbao.derekjacobs.dev bao kv get -mount=secret kia/token
```

Diagnostic:

| Contents | Meaning |
| --- | --- |
| `access_token: ""` + `cleared_at` + `cleared_reason` | **rmtoken died.** Go to step 3. |
| Full blob (`refresh_token`, `device_id`, `stamp`, …) | Something else. Go to step 4. |

`clear_token()` is narrowly gated — it fires only on `AuthenticationOTPRequired` or
an `OTPRequest` returned from `refresh_access_token`. A tombstone is always a **real
expiry**, never a transient Kia blip.

### No `bao` CLI or root token handy

Authenticate as the collector's own ServiceAccount:

```bash
kubectl port-forward -n openbao svc/openbao 18200:8200 &
SAT=$(kubectl create token kia-collector -n home --duration=10m)
TOK=$(curl -s -X POST http://127.0.0.1:18200/v1/auth/kubernetes/login \
  -d "{\"role\":\"kia-collector\",\"jwt\":\"$SAT\"}" | jq -r '.auth.client_token')
curl -s -H "X-Vault-Token: $TOK" \
  http://127.0.0.1:18200/v1/secret/data/kia/token | jq '.data'
```

The SA can read `secret/data/kia/token` but **not** `secret/metadata/kia/token` —
both LIST and version metadata return `permission denied`. Read prior versions with
`?version=N` instead (the last good one is usually `current - 1`).

## 3. Re-authenticate (interactive, needs an OTP)

Two steps on purpose. Do **not** use `kubectl run -it --command -- python setup.py`:
`run` attaches *after* the container starts, so the "OTP required / email vs sms?"
prompt is lost to the attach race and you end up blind-pressing enter at a blank
screen. `exec -it` attaches before the command starts.

```bash
IMG=gitea.derekjacobs.dev/bluevulpine/kia-collector:9-25d82476   # match the deployed tag

kubectl run kia-setup -n home --restart=Never --image="$IMG" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"kia-collector\",\"containers\":[{\"name\":\"kia-setup\",\"image\":\"$IMG\",\"command\":[\"sleep\",\"3600\"],\"envFrom\":[{\"configMapRef\":{\"name\":\"kia-collector-config\"}},{\"secretRef\":{\"name\":\"kia-collector-secret\"}}]}]}}"

kubectl wait --for=condition=ready pod/kia-setup -n home --timeout=120s
kubectl exec -n home kia-setup -it -- python setup.py
kubectl delete pod -n home kia-setup
```

At `Send OTP via [e]mail or [s]ms?` an **empty answer means SMS** — the code tests
`choice.startswith("e")`, so only a leading `e` picks email.

Interactive prompts do not work under Claude Code's `!` shell mode; run this from a
real terminal.

No `imagePullSecrets` needed (the `kia-collector` SA suffices). `kubectl run` has no
`--validate` flag — that is `apply`/`create` only.

## 4. Verify, then let the alerts clear themselves

```bash
kubectl get cronjob -n home \
  -o custom-columns=NAME:.metadata.name,LAST_SUCCESS:.status.lastSuccessfulTime | grep kia
```

The next `*/10` run should complete in ~10s. Then leave it alone:

- `KiaCollectorStale` clears on the next evaluation once `lastSuccessfulTime` is current.
- `KiaCollectorJobFailed` keeps firing until the already-failed Jobs age out via
  `ttlSecondsAfterFinished` — **30 min** for `-cached`, **6h** for `-force`. This is
  deliberate (see the comments in `cronjob.yaml`); do not delete the Jobs by hand
  just to silence it.

Today's `-force` run does not retry — the next one is tomorrow at 12:35 UTC.

## Expiry cadence — do not plan around ~90 days

The collector README used to claim the rmtoken lasts ~90 days. Measured gaps on this
account:

| Re-auth | Gap |
| --- | --- |
| 2026-07-11 (initial setup) | — |
| 2026-08-11T01:10Z | 31 days |
| 2026-08-23T23:00Z | 12.9 days |

Kia kills the rmtoken server-side well before its nominal expiry, and the stored
`valid_until` **lies**: on 2026-08-23 the token claimed validity until
2026-08-24T21:50Z while Kia had already rejected it ~23h earlier. Treat re-auth as an
on-alert chore, never a calendar one.

Separately (and by design), Kia USA kills the session *sid* server-side within ~10
min regardless of `valid_until`, which is why the collector re-logins via the stored
rmtoken on **every** run (kia_uvo #558 / #722).

## Detection gap worth knowing

The 2026-08-23 expiry ran ~18h before anyone looked, across ~108 failed cached runs.
Both alerts fired correctly and promptly — the delay was purely in someone noticing
the Pushover notification. Nothing to fix in the rules.

## Related

- `kubernetes/apps/home/kia-collector/app/cronjob.yaml` — schedules and the
  :35-not-:30 rationale
- `kubernetes/apps/home/kia-collector/app/prometheusrule.yaml` — the three alerts
- Collector source lives in a separate Gitea repo (`~/Repositories/kia-collector`),
  not in flux-talos
