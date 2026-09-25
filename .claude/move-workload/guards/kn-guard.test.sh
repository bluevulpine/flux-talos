#!/bin/bash
# kn-guard.test.sh — self-contained refuse/allow suite for kn-guard.sh. No cluster, no network: a logging FAKE kubectl is first on PATH and every "refuse" test also
# asserts that ZERO kubectl calls were made (the fake is what a bypass would have reached).
#   /bin/bash kn-guard.test.sh [path/to/kn-guard.sh]       (default: the kn-guard.sh next to this file)
# Exit status = number of failing tests. Used by kn-guard.mutation.sh to prove the tests FAIL when the guard is weakened.
# shellcheck disable=SC2016
# ^ test commands are single-quoted on purpose: they are evaluated by the inner /bin/bash after the guard is sourced.
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 99; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KG=${1:-$HERE/kn-guard.sh}
W=$(mktemp -d "${TMPDIR:-/tmp}/kn-guard-test.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/kubectl" <<'EOF'
#!/bin/bash
# logging fake: NEVER talks to a cluster
echo "$*" >> "$KN_FAKE_LOG"
echo "KUBERC=${KUBERC-unset} KUBECTL_KUBERC=${KUBECTL_KUBERC-unset}" >> "$KN_FAKE_ENV"
cat > "$KN_FAKE_STDIN" 2>/dev/null || true
exit 0
EOF
chmod 755 "$W/bin/kubectl"
export KN_FAKE_LOG=$W/calls.log KN_FAKE_ENV=$W/env.log KN_FAKE_STDIN=$W/stdin.log PATH=$W/bin:$PATH KUBECONFIG=$W/dead
case "$(command -v kubectl)" in "$W"/bin/kubectl) ;; *) echo "REFUSING: kubectl is [$(command -v kubectl)], not the fake" >&2; exit 99;; esac
unset KUBERNETES_MASTER
# a limited PATH with NO jq (macOS ships /usr/bin/jq, so "missing" must be made real): only the tools kn needs
mkdir -p "$W/nojq"; for t_ in env cat head; do ln -s "$(command -v $t_)" "$W/nojq/$t_"; done; ln -s "$W/bin/kubectl" "$W/nojq/kubectl"
mkdir -p "$W/nopy"; for t_ in env cat head; do ln -s "$(command -v $t_)" "$W/nopy/$t_"; done; ln -s "$W/bin/kubectl" "$W/nopy/kubectl"; ln -s "$(command -v jq)" "$W/nopy/jq"
export PATH_NOJQ=$W/nojq PATH_NOPY=$W/nopy
pass=0; fail=0; FAILED=""
# t <name> <ok|refuse> <cmd> [refusal-message-substring]: runs in a fresh /bin/bash with the guard sourced. For refuse tests the optional 4th argument asserts WHICH rule
# refused (the message must contain it), so a test cannot pass because some OTHER check happened to fire first.
t() {
  local name=$1 exp=$2 cmd=$3 want=${4:-} out rc n
  : > "$KN_FAKE_LOG"; : > "$KN_FAKE_ENV"; : > "$KN_FAKE_STDIN"
  out=$(/bin/bash -c 'export KN_NAMESPACES="x-old x-new"; source "$1"; shift; eval "$*"' _ "$KG" "$cmd" 2>&1 </dev/null); rc=$?
  n=$(wc -l < "$KN_FAKE_LOG" | tr -d ' '); LAST_OUT=$out
  if [ "$exp" = ok ] && [ "$rc" -eq 0 ] && [ "$n" -ge 1 ]; then pass=$((pass+1)); echo "PASS  $name"
  elif [ "$exp" = refuse ] && [ "$rc" -ne 0 ] && [ "$n" -eq 0 ] && { [ -z "$want" ] || grep -qF -- "$want" <<<"$out"; }; then pass=$((pass+1)); echo "PASS  $name"
  else fail=$((fail+1)); FAILED="$FAILED|$name"; echo "FAIL  $name  (rc=$rc kubectl-calls=$n${want:+ wanted-message=[$want]}) :: $(head -c 200 <<<"$out" | head -1)"; fi
}
echo "== namespace pinning =="
t "ns outside the list refused"                      refuse 'kn other get pods'
t "no namespace refused"                             refuse 'kn'
t "namespace only, no verb refused"                  refuse 'kn x-old'
t "empty KN_NAMESPACES refuses everything"           refuse 'KN_NAMESPACES="" kn x-old get pods'
t "allowed namespace + plain get"                    ok     'kn x-old get pods'
echo "== namespace overrides (each refused; the fake must see ZERO calls) =="
for f in '-n x' '-nx' '-n=x' '--namespace x' '--namespace=x' '-A' '-A=true' '--all-namespaces' '--all-namespaces=true'; do
  t "get pods $f" refuse "kn x-old get pods $f"
done
echo "== the second-pass review's COMBINED / ATTACHED short-flag bypasses (each must be refused BY THE FLAG RULE) =="
SD="single-dash tokens longer than 2 characters"
t "N2: get pods -RA -o yaml"                         refuse 'kn x-old get pods -RA -o yaml' "$SD"
t "N2: get pods -RA"                                 refuse 'kn x-old get pods -RA' "$SD"
t "N2: get pods -Rnkube-system"                      refuse 'kn x-old get pods -Rnkube-system' "$SD"
t "N2: delete pvc hermes -Rnkube-system"             refuse 'kn x-old delete pvc hermes -Rnkube-system' "$SD"
t "N2: logs pod/x -pnkube-system"                    refuse 'kn x-old logs pod/x -pnkube-system' "$SD"
t "N2: get pods -A=true"                             refuse 'kn x-old get pods -A=true' "$SD"
t "N2: get pods -shttps://evil:6443"                 refuse 'kn x-old get pods -shttps://evil:6443' "$SD"
t "N2: get pods -Rshttps://evil:6443"                refuse 'kn x-old get pods -Rshttps://evil:6443' "$SD"
t "N2: get pods -wA"                                 refuse 'kn x-old get pods -wA' "$SD"
t "N2: get pods -l x=y -A (the -A itself, separate value for -l)" refuse 'kn x-old get pods -l x=y -A' "short flag [-A]"
t "N2: get pods -oname -A"                           refuse 'kn x-old get pods -oname -A' "short flag [-A]"
t "combined -ow (short flags stacked)"               refuse 'kn x-old get pods -ow' "$SD"
t "attached -ojsonpath=…"                            refuse "kn x-old get pods -ojsonpath='{.items}'" "$SD"
t "attached -cfoo"                                   refuse 'kn x-old logs pod/x -cfoo' "$SD"
t "attached -lapp=x"                                 refuse 'kn x-old get pods -lapp=x' "$SD"
echo "== F1: short-flag arity is decided PER VERB (logs -p is a BOOLEAN; the next token is still a flag) =="
t "F1: logs pod/x -p -nkube-system"                  refuse 'kn x-old logs pod/x -p -nkube-system' "$SD"
t "F1: logs -p -nkube-system pod/x"                  refuse 'kn x-old logs -p -nkube-system pod/x' "$SD"
t "F1: logs pod/x -p -shttps://evil:6443"            refuse 'kn x-old logs pod/x -p -shttps://evil:6443' "$SD"
t "F1: logs pod/x -p --namespace=kube-system"        refuse 'kn x-old logs pod/x -p --namespace=kube-system' "denied flag"
t "F1: logs pod/x -p --kubeconfig=/other/config"     refuse 'kn x-old logs pod/x -p --kubeconfig=/other/config' "denied flag"
t "F1: logs pod/x -p --context=prod"                 refuse 'kn x-old logs pod/x -p --context=prod' "denied flag"
t "F1: logs pod/x -p --as=system:admin"              refuse 'kn x-old logs pod/x -p --as=system:admin' "denied flag"
t "F1: logs -p secrets/x (the kind check is not skipped)" refuse 'kn x-old logs -p secrets/x' "kind [secrets]"
t "F1: logs pod/x -p alone is fine (boolean --previous)" ok   'kn x-old logs pod/x -p'
t "F1: logs -c is a VALUE (container) in logs"       ok     'kn x-old logs pod/x -c app'
t "F1: logs -c -nkube-system: the value is consumed by -c (kubectl does the same)" ok 'kn x-old logs pod/x -c -nkube-system'
t "F1: patch -p is a VALUE"                          ok     "kn x-old patch pvc x -p '{}'"
t "F1: get -p refused (no such short flag for get)"  refuse 'kn x-old get pods -p x' "short flag [-p] is not allowed for 'get'"
t "F1: delete -c refused"                            refuse 'kn x-old delete pod x -c y' "short flag [-c] is not allowed for 'delete'"
t "F1: describe -o refused"                          refuse 'kn x-old describe pods -o json' "short flag [-o] is not allowed for 'describe'"
t "F1: logs -o refused"                              refuse 'kn x-old logs pod/x -o json' "short flag [-o] is not allowed for 'logs'"
t "F1: a verb added through KN_VERBS gets NO short flags" refuse 'KN_VERBS="get top" kn x-old top pods -l x=y' "short flag [-l] is not allowed for 'top'"
t "X1: --output=json does NOT consume the next token (-nkube-system stays a flag)" refuse 'kn x-old get pods --output=json -nkube-system' "$SD"
t "X1: --selector=x=y does not consume the next token" refuse 'kn x-old get pods --selector=x=y -nkube-system' "$SD"
t "--output json (separate value) is consumed"       ok     'kn x-old get pods --output json'
echo "== credential / cluster / file flags in every form =="
for f in '--context x' '--context=x' '--cluster x' '--cluster=x' '--user x' '--user=x' '--kubeconfig=/x' '--kubeconfig /x' '-s x' '-s=x' '--server x' '--server=https://x' \
         '--as x' '--as=x' '--as-group x' '--as-group=x' '--as-uid=x' '--token x' '--token=x' '--raw /x' '--raw=/x' '--insecure-skip-tls-verify' '--insecure-skip-tls-verify=true' \
         '--tls-server-name=x' '--tls-server-name x' '--certificate-authority=/x' '--certificate-authority /x' '--client-certificate=/x' '--client-key=/x' '--client-key /x' \
         '--client-certificate-data=x' '--username=x' '--password=x' '--filename=x' '--kustomize=x' '--recursive' '-R' '-k x' '-f x' '--request-timeout=1' '--v=9' '-v=9' '-h' '-w' '--' '-'; do
  case "$f" in
    "-f x") msg="-f is only accepted";;
    "--") msg="'--' is not accepted";;
    --*) fn=${f%% *}; fn=${fn%%=*}; DENY=" --namespace --all-namespaces --context --cluster --user --kubeconfig --server --as --as-group --as-uid --token --raw --insecure-skip-tls-verify --tls-server-name --certificate-authority --client-certificate --client-key --client-certificate-data --proxy-url --v --vmodule --log-file --log-dir --username --password --filename --kustomize --recursive "; case "$DENY" in
        *" $fn "*) msg="denied flag";; *) msg="not on the allow-list";; esac;;
    -?|-?" "*|-?=*) msg="short flag";;
    *) msg="not on the allow-list";;
  esac
  t "get pods $f" refuse "kn x-old get pods $f" "$msg"
done
t "-f on a non-apply verb refused"                   refuse 'kn x-old delete -f -'
t "--all not on the default allow-list"              refuse 'kn x-old delete pods --all'
t "--all allowed only via KN_EXTRA_BOOL_FLAGS (as --all=true)" ok 'KN_EXTRA_BOOL_FLAGS="--all" kn x-old delete pods --all=true'
t "--timeout with a space refused (= required)"      refuse 'kn x-old wait --for=delete pod/x --timeout 120s'
t "--replicas with a space refused"                  refuse 'kn x-old scale deploy/x --replicas 0'
t "--cascade with a space refused"                   refuse 'kn x-old delete pod x --cascade foreground'
t "--for with a space refused"                       refuse 'kn x-old wait --for delete pod/x'
t "unknown long flag refused"                        refuse 'kn x-old get pods --chunk-size=1'
echo "== environment overrides =="
t "KUBERNETES_MASTER set refused"                    refuse 'KUBERNETES_MASTER=https://evil kn x-old get pods'
t "KN_KUBECONFIG_PIN mismatch refused"               refuse 'KN_KUBECONFIG_PIN=/other kn x-old get pods'
t "KN_KUBECONFIG_PIN match allowed"                  ok     'KN_KUBECONFIG_PIN="$KUBECONFIG" kn x-old get pods'
echo "== verbs =="
for v in exec cp port-forward debug proxy attach auth run create edit replace config plugin rollout expose set taint cordon drain top api-resources; do
  t "verb [$v] refused" refuse "kn x-old $v pods"
done
t "exec stays refused even if KN_VERBS lists it"     refuse 'KN_VERBS="get exec" kn x-old exec pod/x id'
t "port-forward stays refused even if KN_VERBS lists it" refuse 'KN_VERBS="get port-forward" kn x-old port-forward pod/x 80'
t "auth can-i refused"                               refuse 'kn x-old auth can-i get secrets'
echo "== kinds: secrets and everything cluster-scoped or foreign =="
for k in secret secrets Secret SECRETS secret/x secrets/x secrets.v1 pvc,secret pod,secrets pods,pvc,secrets \
         pv persistentvolume persistentvolumes ns namespace namespaces node nodes crd customresourcedefinition clusterrole clusterrolebinding clusterissuers clustersecretstores \
         volumes.longhorn.io snapshots.longhorn.io settings.longhorn.io storageclass storageclasses volumesnapshotcontent volumesnapshotcontents all; do
  t "get $k" refuse "kn x-old get $k"
done
t "describe secrets refused"                         refuse 'kn x-old describe secrets'
t "get secret -o yaml refused"                       refuse 'kn x-old get secret -o yaml'
t "delete pvc/a secret/b refused (kind/name smuggling)" refuse 'kn x-old delete pvc/a secret/b'
t "delete pvc/a pv/b refused"                        refuse 'kn x-old delete pvc/a pv/b'
t "KN_KINDS replaces the list (pods no longer allowed)" refuse 'KN_KINDS="job" kn x-old get pods'
t "KN_KINDS can allow a kind the default lacks (svc)" ok    'KN_KINDS="svc" kn x-old get svc'
echo "== apply: JSON only; jq parses EVERY document; kubectl gets the CANONICAL form =="
JOB='{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"x"}}'
JOB2='{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"y"}}'
M="every JSON document must be an object"
eq_stdin() { if [ "$(cat "$KN_FAKE_STDIN")" = "$1" ]; then pass=$((pass+1)); echo "PASS  $2"; else fail=$((fail+1)); FAILED="$FAILED|$2"; echo "FAIL  $2 :: got [$(cat "$KN_FAKE_STDIN")]"; fi; }
t "apply without -f - refused (rule: apply needs -f -)" refuse "printf '%s' '$JOB' | kn x-old apply" "apply needs -f -"
t "apply -f file refused (even with a valid Job on stdin: kubectl would read the FILE)" refuse "printf '%s' '$JOB' | kn x-old apply -f /tmp/x.yaml" "-f accepts only '-'"
t "apply -k refused"                                 refuse 'kn x-old apply -k /tmp/x' "-k"
t "apply -f - a plain Job allowed"                   ok     "printf '%s' '$JOB' | kn x-old apply -f -"
t "apply canonical form: kubectl received compact JSON, not the original bytes" ok "printf '{ \"apiVersion\" : \"batch/v1\",\n \"kind\":\"Job\", \"metadata\":{\"name\":\"x\"} }' | kn x-old apply -f -"
eq_stdin "$JOB" "  stdin of kubectl == the canonical JSON that was checked"
t "apply -f - two Jobs (a stream): both documents forwarded" ok "printf '%s\n%s\n' '$JOB' '$JOB2' | kn x-old apply -f -"
eq_stdin "$JOB
$JOB2" "  both documents present, one per line"
t "apply -f - PersistentVolume refused"              refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"PersistentVolume\",\"metadata\":{\"name\":\"x\"}}' | kn x-old apply -f -" "$M"
t "apply -f - Namespace refused"                     refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"x\"}}' | kn x-old apply -f -" "$M"
t "apply -f - Secret refused"                        refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"x\"}}' | kn x-old apply -f -" "$M"
t "apply -f - Job naming a namespace refused"        refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"metadata\":{\"name\":\"x\",\"namespace\":\"ai\"}}' | kn x-old apply -f -" "$M"
t "apply -f - Job with a namespace key deep in the spec refused" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"spec\":{\"a\":{\"namespace\":\"ai\"}}}' | kn x-old apply -f -" "$M"
t "apply -f - Job with a Namespace-cased key refused (case-insensitive struct decoding)" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"metadata\":{\"Namespace\":\"ai\"}}' | kn x-old apply -f -" "$M"
t "apply -f - Job then a PV document refused (every document is checked)" refuse "printf '%s\n%s\n' '$JOB' '{\"apiVersion\":\"v1\",\"kind\":\"PersistentVolume\"}' | kn x-old apply -f -" "$M"
t "apply -f - a PV document hidden LAST among many refused" refuse "printf '%s\n%s\n%s\n%s\n' '$JOB' '$JOB' '$JOB2' '{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"}' | kn x-old apply -f -" "$M"
t "apply -f - a PV document FIRST then Jobs refused" refuse "printf '%s\n%s\n' '{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"}' '$JOB' | kn x-old apply -f -" "$M"
t "apply -f - two documents on ONE line refused (jq -e used to judge only the last)" refuse "printf '%s %s\n' '{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"}' '$JOB' | kn x-old apply -f -" "$M"
t "apply -f - no kind refused"                       refuse "printf '%s' '{\"apiVersion\":\"v1\",\"metadata\":{\"name\":\"x\"}}' | kn x-old apply -f -" "$M"
t "apply -f - no apiVersion refused"                 refuse "printf '%s' '{\"kind\":\"Job\",\"metadata\":{\"name\":\"x\"}}' | kn x-old apply -f -" "$M"
t "apply -f - a JSON null / array / string document refused" refuse "printf 'null' | kn x-old apply -f -" "$M"
t "apply -f - a JSON array refused"                  refuse "printf '[%s]' '$JOB' | kn x-old apply -f -" "$M"
t "apply -f - empty stdin refused"                   refuse "printf '' | kn x-old apply -f -" "no document"
t "apply -f - only whitespace refused"               refuse "printf '  \n' | kn x-old apply -f -" "no document"
t "apply -f - a YAML manifest is REFUSED (JSON only)" refuse "printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: x}\n' | kn x-old apply -f -" "STRICT JSON"
t "apply -f - a YAML PersistentVolume is refused (JSON only)" refuse "printf \"apiVersion: v1\nkind: 'PersistentVolume'\n\" | kn x-old apply -f -" "STRICT JSON"
t "apply -f - a YAML octal-ish scalar (0400) is refused: no YAML-version ambiguity" refuse "printf 'apiVersion: batch/v1\nkind: Job\nspec: {mode: 0400}\n' | kn x-old apply -f -" "STRICT JSON"
t "apply -f - truncated JSON refused"                refuse "printf '{\"kind\":\"Job\"' | kn x-old apply -f -" "STRICT JSON"
echo "== R4-1: STRICT JSON — jq's lenient parse would rewrite these and change their meaning for kubectl =="
J1='{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"x"}'
for v in 0400 +1 .5 -.5 1. 01 00 0x10 nan NaN -nan infinity Infinity -Infinity -infinity 1e999 -1e999; do
  t "R4-1: number literal $v refused" refuse "printf '%s' '$J1,\"spec\":{\"m\":$v}}' | kn x-old apply -f -" "STRICT JSON"
done
t "R4-1: defaultMode 0400 in a Secret volume (the reviewer's proof)" refuse "printf '%s' '$J1,\"spec\":{\"volumes\":[{\"secret\":{\"secretName\":\"s\",\"defaultMode\":0400}}]}}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: a trailing comma is refused"                refuse "printf '%s' '$J1,}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: single-quoted strings are refused"          refuse "printf \"{'apiVersion':'batch/v1','kind':'Job'}\" | kn x-old apply -f -" "STRICT JSON"
t "R4-1: a comment is refused"                       refuse "printf '%s\n// c\n' '$J1}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: a raw newline inside a string is refused"   refuse "printf '{\"apiVersion\":\"batch/v1\",\"kind\":\"Jo\nb\"}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: invalid UTF-8 is refused"                   refuse "printf '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"a\":\"\\377\"}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: a JSON document followed by YAML is refused" refuse "printf '%s\nkind: Namespace\n' '$J1}' | kn x-old apply -f -" "STRICT JSON"
t "R4-1: valid numbers still pass: 0 -0 0.5 -1 1e3 1E-2 12345678901234567890" ok "printf '%s' '$J1,\"spec\":{\"a\":[0,-0,0.5,-1,1e3,1E-2,12345678901234567890]}}' | kn x-old apply -f -"
t "R4-1: null / true / false pass"                   ok     "printf '%s' '$J1,\"spec\":{\"a\":null,\"b\":true,\"c\":false}}' | kn x-old apply -f -"
echo "== R4-4: apiVersion and kind are compared as separate fields =="
t "R4-4: apiVersion 'batch' + kind 'v1/Job' does not match batch/v1/Job" refuse "printf '%s' '{\"apiVersion\":\"batch\",\"kind\":\"v1/Job\"}' | kn x-old apply -f -" "$M"
t "R4-4: apiVersion 'batch/v1/' + kind 'Job' does not match"            refuse "printf '%s' '{\"apiVersion\":\"batch/v1/\",\"kind\":\"Job\"}' | kn x-old apply -f -" "$M"
t "R4-4: a KN_APPLY_KINDS entry '/Job' (empty apiVersion) fails closed" refuse "printf '%s' '{\"apiVersion\":\"\",\"kind\":\"Job\"}' | KN_APPLY_KINDS='/Job' kn x-old apply -f -" "must be <apiVersion>/<Kind>"
t "R4-4: core group entry v1/ConfigMap matches apiVersion v1 + kind ConfigMap" ok "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\"}' | KN_APPLY_KINDS='v1/ConfigMap' kn x-old apply -f -"
echo "== R4-3: log flags that write files or raise verbosity are denied by name =="
for f in --log-file=/tmp/x --log-file --log-dir=/tmp --log-file-max-size=1 --log-backtrace-at=x:1 --log-flush-frequency=1s --v=9 --v --vmodule=x=1 --log_file=/tmp/x; do
  t "R4-3: $f refused (also when listed in KN_EXTRA_BOOL_FLAGS)" refuse "KN_EXTRA_BOOL_FLAGS='--log-file --v --log-dir' kn x-old get pods $f" "denied flag"
done
echo "== R3-1: kubectl treats ANY object with a top-level items key as a LIST and applies each item =="
t "R3-1: Job + items[Namespace] (JSON)"              refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"metadata\":{\"name\":\"x\"},\"items\":[{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"evil\"}}]}' | kn x-old apply -f -" "$M"
t "R3-1: Job + items[ClusterRoleBinding]"            refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"items\":[{\"apiVersion\":\"rbac.authorization.k8s.io/v1\",\"kind\":\"ClusterRoleBinding\"}]}' | kn x-old apply -f -" "$M"
t "R3-1: Job + items[PV hostPath /]"                 refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"items\":[{\"apiVersion\":\"v1\",\"kind\":\"PersistentVolume\",\"spec\":{\"hostPath\":{\"path\":\"/\"}}}]}' | kn x-old apply -f -" "$M"
t "R3-1: Job + items[Secret,Pod] (namespaced kinds outside KN_APPLY_KINDS)" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"items\":[{\"apiVersion\":\"v1\",\"kind\":\"Secret\"},{\"apiVersion\":\"v1\",\"kind\":\"Pod\"}]}' | kn x-old apply -f -" "$M"
t "R3-1: Job with an EMPTY items list is refused too (any items key)" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"items\":[]}' | kn x-old apply -f -" "$M"
t "R3-1: Job with items: null"                       refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"items\":null}' | kn x-old apply -f -" "$M"
t "R3-1: kind List (default config)"                 refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"List\",\"items\":[{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\"}]}' | kn x-old apply -f -" "$M"
t "R3-1: kind List even when KN_APPLY_KINDS lists it" refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"List\",\"items\":[{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"}]}' | KN_APPLY_KINDS='batch/v1/Job v1/List' kn x-old apply -f -" "$M"
t "R3-1: an Items / ITEMS key (case variant) is refused too" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"Items\":[{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"}]}' | kn x-old apply -f -" "$M"
t "R3-1: a Job WITHOUT items and with an items-named env var value is fine (only KEYS count)" ok "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"spec\":{\"note\":\"items\"}}' | kn x-old apply -f -"
echo "== JSON quirks that could make the guard and kubectl disagree =="
t "escaped key \\u006bind: the decoded key is checked"   refuse "printf '%s' '{\"apiVersion\":\"v1\",\"\\u006bind\":\"Namespace\"}' | kn x-old apply -f -" "$M"
t "duplicate keys: the LAST kind wins in jq and in Go; canonical form carries one"  refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"kind\":\"Namespace\"}' | kn x-old apply -f -" "$M"
t "duplicate keys: last kind Job is allowed and canonicalised" ok "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Namespace\",\"kind\":\"Job\"}' | kn x-old apply -f -"
eq_stdin '{"apiVersion":"batch/v1","kind":"Job"}' "  the canonical line has ONE kind key"
t "case-variant root keys KIND / Kind refused"       refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"KIND\":\"Namespace\"}' | kn x-old apply -f -" "$M"
t "case-variant apiversion refused"                  refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"apiversion\":\"v1\"}' | kn x-old apply -f -" "$M"
t "a wrong-cased ONLY root kind (KIND) has no exact kind: refused" refuse "printf '%s' '{\"apiVersion\":\"batch/v1\",\"KIND\":\"Job\"}' | kn x-old apply -f -" "$M"
echo "== R3-6d: apiVersion is pinned with the kind =="
t "apiVersion example.com/v1 + kind Job (a CRD named Job in another group) refused" refuse "printf '%s' '{\"apiVersion\":\"example.com/v1\",\"kind\":\"Job\"}' | kn x-old apply -f -" "$M"
t "apiVersion batch/v1beta1 + kind Job refused"      refuse "printf '%s' '{\"apiVersion\":\"batch/v1beta1\",\"kind\":\"Job\"}' | kn x-old apply -f -" "$M"
t "KN_APPLY_KINDS entry without a group/version fails closed" refuse "printf '%s' '$JOB' | KN_APPLY_KINDS=Job kn x-old apply -f -" "must be <apiVersion>/<Kind>"
t "KN_APPLY_KINDS='batch/v1/Job v1/ConfigMap' (space split) allows a ConfigMap" ok "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\"}' | KN_APPLY_KINDS='batch/v1/Job v1/ConfigMap' kn x-old apply -f -"
t "KN_APPLY_KINDS='batch/v1/Job v1/ConfigMap' still allows the Job" ok "printf '%s' '$JOB' | KN_APPLY_KINDS='batch/v1/Job v1/ConfigMap' kn x-old apply -f -"
t "KN_APPLY_KINDS='batch/v1/Job,v1/ConfigMap' (comma) is NOT a list separator" refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\"}' | KN_APPLY_KINDS='batch/v1/Job,v1/ConfigMap' kn x-old apply -f -" "$M"
t "KN_APPLY_KINDS with a trailing space does not match an empty kind" refuse "printf '%s' '{\"apiVersion\":\"\",\"kind\":\"\"}' | KN_APPLY_KINDS='batch/v1/Job ' kn x-old apply -f -" "$M"
t "KN_APPLY_KINDS widens the manifest kinds"         ok     "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"x\"}}' | KN_APPLY_KINDS=v1/ConfigMap kn x-old apply -f -"
echo "== R3-6: refusal messages never echo manifest content (it may be a Secret's stringData) =="
t "the refusal for a Secret document does not contain its stringData" refuse "printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"stringData\":{\"password\":\"hunter2-TOPSECRET\"}}' | kn x-old apply -f -" "$M"
case "$LAST_OUT" in *TOPSECRET*|*hunter2*) fail=$((fail+1)); FAILED="$FAILED|no manifest echo"; echo "FAIL  the refusal message leaked manifest content: $LAST_OUT";; *) pass=$((pass+1)); echo "PASS  no manifest content in the refusal";; esac
t "the refusal for unparsable input does not echo it either" refuse "printf '%s' 'password: hunter2-TOPSECRET' | kn x-old apply -f -" "STRICT JSON"
case "$LAST_OUT" in *TOPSECRET*|*hunter2*) fail=$((fail+1)); FAILED="$FAILED|no parse echo"; echo "FAIL  the parse refusal leaked: $LAST_OUT";; *) pass=$((pass+1)); echo "PASS  no content in the parse refusal";; esac
echo "== the parser dependency =="
t "apply refused when python3 is missing (the strict validator)" refuse "PATH=\$PATH_NOPY; printf '%s' '$JOB' | kn x-old apply -f -" "apply needs python3"
t "apply refused when jq is missing"                 refuse "PATH=\$PATH_NOJQ; printf '%s' '$JOB' | kn x-old apply -f -" "apply needs jq"
echo "== F3: '=' / trailing '-' positionals no longer skip the kind check =="
t "F3: delete pvc/a clusterrole/x=y"                 refuse 'kn x-old delete pvc/a clusterrole/x=y' "contains '='"
t "F3: get secret/a=b -o yaml"                       refuse 'kn x-old get secret/a=b -o yaml' "contains '='"
t "F3: get secrets,pods=x"                           refuse 'kn x-old get secrets,pods=x' "contains '='"
t "X11: delete pvc/a secret/b- (trailing dash is not a pair outside annotate/label)" refuse 'kn x-old delete pvc/a secret/b-' "kind [secret]"
t "X11: get pvc/a secret/b-"                         refuse 'kn x-old get pvc/a secret/b-' "kind [secret]"
t "F3: annotate pvc x key- (removal pair) is allowed" ok    'kn x-old annotate pvc x kustomize.toolkit.fluxcd.io/prune-'
t "F3: annotate pvc x a=b c=d e- (all pairs)"        ok     'kn x-old annotate pvc x a=b c=d e-'
t "F3: annotate pvc/a clusterrole/x=y is a PAIR after a resource (kubectl's rule): allowed, applies to pvc/a" ok 'kn x-old annotate pvc/a clusterrole/x=y'
t "F3: annotate with a pair BEFORE any resource refused" refuse 'kn x-old annotate a=b pvc x' "contains '='"
t "F3: label pvc x env=prod"                         ok     'kn x-old label pvc x env=prod'
echo "== F4: the caller's IFS and pathname expansion cannot change the classification =="
t "F4: strict-mode IFS: hard-deny list still refuses exec even when KN_VERBS lists it" refuse "IFS=\$'\\n\\t'; KN_NAMESPACES=x-old KN_VERBS=exec KN_KINDS=pod kn x-old exec pod/x id" "never allowed"
t "F4: strict-mode IFS: port-forward still refused"  refuse "IFS=\$'\\n\\t'; KN_NAMESPACES=x-old KN_VERBS=port-forward KN_KINDS=pod kn x-old port-forward pod/x 8080:80" "never allowed"
t "F4: strict-mode IFS: a plain get still works (usability)" ok "IFS=\$'\\n\\t'; kn x-old get pods"
t "F4: IFS=, cannot merge the verb list into one word" ok   "IFS=,; kn x-old get pods"
t "F4: a glob in a kind is not expanded against files (./pods exists)" refuse 'd=$(mktemp -d); cd "$d"; : > pods; kn x-old get "p?ds"; rc=$?; rm -rf "$d"; exit $rc' "kind [p?ds]"
t "F4: the caller's noglob state is restored (set +f stays +f)" ok 'kn x-old get pods; case $- in *f*) exit 1;; *) exit 0;; esac'
t "F4: the caller's noglob state is restored (set -f stays -f)" ok 'set -f; kn x-old get pods; case $- in *f*) exit 0;; *) exit 1;; esac'
echo "== R3-6: empty and '='-leading positionals =="
t "R3-6a: get '' secrets (empty positional passed the kind check vacuously)" refuse 'kn x-old get "" secrets' "empty or starts with '='"
t "R3-6a: get pods ''"                               refuse "kn x-old get pods ''" "empty or starts with '='"
t "R3-6b: annotate pvc/a =b/c secret/y a=b (kubectl treats =b/c as a RESOURCE)" refuse 'kn x-old annotate pvc/a =b/c secret/y a=b' "empty or starts with '='"
t "R3-6b: delete pvc =x"                             refuse 'kn x-old delete pvc =x' "empty or starts with '='"
echo "== Y1 / IFS: the guard's own noglob and IFS lines are exercised =="
t "Y1: a glob in KN_NAMESPACES is NOT expanded against files (kube-system exists in cwd)" refuse 'd=$(mktemp -d); cd "$d"; : > kube-system; KN_NAMESPACES="*" kn kube-system get pods; rc=$?; rm -rf "$d"; exit $rc' "REFUSE ns="
t "Y1: a glob in KN_KINDS is NOT expanded (a file named pods exists)" refuse 'd=$(mktemp -d); cd "$d"; : > pods; : > secrets; KN_KINDS="*" kn x-old get secrets; rc=$?; rm -rf "$d"; exit $rc' "kind [secrets]"
t "Y1/IFS: strict-mode IFS does not break the namespace list (needs kn's own IFS reset)" ok "IFS=\$'\\n\\t'; kn x-old get pods"
t "Y1/IFS: IFS=x cannot split a verb or kind list differently" ok "IFS=x; kn x-old get pods"
t "Y1/IFS: IFS=- and an allowed pvc" ok "IFS=-; kn x-old get pvc moveprobe2"
echo "== F5 / R3-4: the named-deny list wins; extra flags come LAST and only as --flag=value =="
t "F5: KN_EXTRA_BOOL_FLAGS=--namespace cannot re-enable it" refuse 'KN_EXTRA_BOOL_FLAGS="--namespace" kn x-old delete pvc x --namespace=kube-system' "denied flag"
t "F5: KN_EXTRA_BOOL_FLAGS=--all-namespaces"         refuse 'KN_EXTRA_BOOL_FLAGS="--all-namespaces" kn x-old get pods --all-namespaces' "denied flag"
t "F5: KN_EXTRA_BOOL_FLAGS=--server"                 refuse 'KN_EXTRA_BOOL_FLAGS="--server" kn x-old get pods --server=https://x' "denied flag"
t "F5: KN_EXTRA_BOOL_FLAGS=--client-key"             refuse 'KN_EXTRA_BOOL_FLAGS="--client-key" kn x-old get pods --client-key=/x' "denied flag"
t "R3-4: an extra flag is accepted ONLY as --flag=value"    ok  'KN_EXTRA_BOOL_FLAGS="--all" kn x-old delete pods --all=true'
t "R3-4: an extra flag in the bare form is refused (kn cannot know its arity)" refuse 'KN_EXTRA_BOOL_FLAGS="--all" kn x-old delete pods --all' "must be written --all=<value>"
t "R3-4: KN_EXTRA_BOOL_FLAGS=--template cannot swallow a kind (get --template pods secrets)" refuse 'KN_EXTRA_BOOL_FLAGS="--template" kn x-old get --template pods secrets' "must be written"
t "R3-4: extra flags cannot downgrade a built-in value flag (--selector)" refuse 'KN_EXTRA_BOOL_FLAGS="--selector" kn x-old delete pvc --selector app' "plain equality terms"
t "R3-4: ... nor with a match-everything selector"   refuse "KN_EXTRA_BOOL_FLAGS='--selector' kn x-old delete pvc --selector='x!=y'" "plain equality terms"
t "R3-4: an extra entry naming a built-in value flag (--output) changes nothing: its value is still consumed, as kubectl does" ok 'KN_EXTRA_BOOL_FLAGS="--output" kn x-old get pods --output -nkube-system'
for f in --all_namespaces --all_namespaces=true --insecure_skip_tls_verify --insecure_skip_tls_verify=true --as_group=x --tls_server_name=x --certificate_authority=/x --client_key=/x --kube_config=/x; do
  case "$f" in --kube_config*) msg="not on the allow-list";; *) msg="denied flag";; esac
  t "R3-4: underscore spelling $f is normalised and refused" refuse "kn x-old get pods $f" "$msg"
done
for f in --proxy-url=http://evil:3128 --proxy-url --as-user-extra=a=b --cache-dir=/tmp/x --kuberc=/tmp/evil --proxy_url=http://x; do
  t "R3-4: $f refused by name" refuse "kn x-old get pods $f" "denied flag"
done
t "R3-4: an extra-flag underscore spelling is normalised too" ok 'KN_EXTRA_BOOL_FLAGS="--dry-run-x" kn x-old get pods --dry_run_x=true'
echo "== R3-5: the deny/allow lists are not variables a caller can blank =="
t "R3-5: KN_HARD_DENY_VERBS='' cannot re-enable exec"       refuse 'KN_HARD_DENY_VERBS="" KN_VERBS=exec KN_KINDS=pod kn x-old exec pod/x id' "never allowed"
t "R3-5: _KN_HARD_DENY_VERBS='' / HARD_DENY_VERBS=''"       refuse 'HARD_DENY_VERBS="" _KN_HARD_DENY_VERBS="" KN_VERBS=exec KN_KINDS=pod kn x-old exec pod/x id' "never allowed"
t "R3-5: KN_LONG_DENY='' + extra flag cannot re-enable --namespace" refuse 'KN_LONG_DENY="" KN_EXTRA_BOOL_FLAGS=--namespace kn x-old get pods --namespace=kube-system' "denied flag"
t "R3-5: KN_LONG_SEP that adds --namespace does nothing" refuse 'KN_LONG_SEP="--output --namespace" KN_LONG_DENY="" kn x-old get pods --namespace kube-system' "denied flag"
t "R3-5: KN_MUTATE_VERBS='' cannot lift the controller-kind rule" refuse "KN_MUTATE_VERBS='' kn x-old patch ks x --type merge -p '{}'" "controller kind"
t "R3-5: KN_SELECTOR_VERBS='' cannot lift the selector rule" refuse "KN_SELECTOR_VERBS='' kn x-old delete pvc -l 'x!=y'" "plain equality terms"
t "R3-5: KN_SELECTOR_RE='.*' cannot lift the selector rule" refuse "KN_SELECTOR_RE='.*' kn x-old delete pvc -l 'x!=y'" "plain equality terms"
t "R3-5: KN_DEFAULT_VERBS overridden to add exec"           refuse 'KN_DEFAULT_VERBS="get exec" kn x-old exec pod/x id' "never allowed"
t "R3-5: KN_DEFAULT_KINDS overridden to add secrets"        refuse 'KN_DEFAULT_KINDS="pod secrets" kn x-old get secrets' "kind [secrets]"
echo "== F6: selectors on write verbs must be plain equality terms =="
for sel in "x!=y" "nonexistent!=y" "x notin (a,b)" "!x" "x" "x in (a)" "" "x=y,z!=w" "x=y z=w" "x>1"; do
  t "F6: delete pvc -l '$sel'"                        refuse "kn x-old delete pvc -l '$sel'" "plain equality terms"
done
t "F6: delete pvc --field-selector 'metadata.name!=_'" refuse "kn x-old delete pvc --field-selector 'metadata.name!=_'" "plain equality terms"
t "F6: delete pvc --field-selector='metadata.name!=_'" refuse "kn x-old delete pvc --field-selector='metadata.name!=_'" "plain equality terms"
t "F6: delete pvc --selector='!x'"                    refuse "kn x-old delete pvc --selector='!x'" "plain equality terms"
t "F6: patch pvc -l 'x!=y'"                           refuse "kn x-old patch pvc -l 'x!=y' -p '{}'" "plain equality terms"
t "F6: annotate pvc -l 'x!=y' a=b"                    refuse "kn x-old annotate pvc -l 'x!=y' a=b" "plain equality terms"
t "Y2: label pvc -l 'x!=y' a=b"                      refuse "kn x-old label pvc -l 'x!=y' a=b" "plain equality terms"
t "Y3: apply -f - -l 'x!=y'"                         refuse "printf '%s' '$JOB' | kn x-old apply -f - -l 'x!=y'" "plain equality terms"
t "F6: scale deploy -l 'x!=y' --replicas=0"           refuse "kn x-old scale deploy -l 'x!=y' --replicas=0" "plain equality terms"
t "F6: delete pod -l app.kubernetes.io/name=moveprobe2 (equality) allowed" ok "kn x-old delete pod -l app.kubernetes.io/name=moveprobe2"
t "F6: delete pod -l a=b,c=d allowed"                 ok "kn x-old delete pod -l a=b,c=d"
t "F6: delete pod --field-selector involvedObject.name=x allowed" ok "kn x-old delete pod --field-selector involvedObject.name=x"
t "F6: a READ (get) with a negative selector is fine" ok "kn x-old get pods -l 'x!=y'"
t "F6: logs with a selector is unrestricted"          ok "kn x-old logs -l 'x!=y'"
echo "== F7: kubectl always runs with the kuberc disabled =="
t "F7: kubectl is called with KUBERC=off KUBECTL_KUBERC=false" ok 'kn x-old get pods'
if grep -qx 'KUBERC=off KUBECTL_KUBERC=false' "$KN_FAKE_ENV"; then pass=$((pass+1)); echo "PASS  F7: the fake saw KUBERC=off KUBECTL_KUBERC=false"; else fail=$((fail+1)); FAILED="$FAILED|F7 env"; echo "FAIL  F7: env seen by kubectl: [$(cat "$KN_FAKE_ENV")]"; fi
t "F7: a hostile caller KUBERC does not reach kubectl" ok 'KUBERC=/tmp/evil-kuberc KUBECTL_KUBERC=true kn x-old get pods'
if grep -qx 'KUBERC=off KUBECTL_KUBERC=false' "$KN_FAKE_ENV"; then pass=$((pass+1)); echo "PASS  F7: overridden to off/false even when the caller set them"; else fail=$((fail+1)); FAILED="$FAILED|F7 env2"; echo "FAIL  F7: env seen by kubectl: [$(cat "$KN_FAKE_ENV")]"; fi
t "F7: the apply path also runs with the kuberc disabled" ok "printf '$JOB' | KUBERC=/tmp/evil kn x-old apply -f -"
if grep -qx 'KUBERC=off KUBECTL_KUBERC=false' "$KN_FAKE_ENV"; then pass=$((pass+1)); echo "PASS  F7: apply path env"; else fail=$((fail+1)); FAILED="$FAILED|F7 env3"; echo "FAIL  F7 apply env: [$(cat "$KN_FAKE_ENV")]"; fi
echo "== D1: controller kinds are read/delete only =="
for k in ks kustomization kustomizations hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets; do
  t "D1: patch $k refused"                            refuse "kn x-old patch $k x --type merge -p '{}'" "controller kind"
  t "D1: annotate $k refused"                         refuse "kn x-old annotate $k x a=b" "controller kind"
  t "D1: label $k refused"                            refuse "kn x-old label $k x a=b" "controller kind"
  t "D1: scale $k refused"                            refuse "kn x-old scale $k x --replicas=0" "controller kind"
  t "D1: get $k allowed"                              ok     "kn x-old get $k"
  t "D1: delete $k allowed (the caller decides; see the header)" ok "kn x-old delete $k x"
done
t "D1: patch ks/name (kind/name form) refused"        refuse "kn x-old patch ks/x --type merge -p '{}'" "controller kind"
t "D1: get ks,hr allowed"                             ok     "kn x-old get ks,hr"
echo "== R4-2: KN_CONTROLLER_KINDS is ADDITIVE — it can never remove a built-in controller kind =="
t "R4-2: KN_CONTROLLER_KINDS='' does not lift the ks write ban"   refuse "KN_CONTROLLER_KINDS='' kn x-old patch ks/x --type=merge -p '{\"spec\":{\"targetNamespace\":\"kube-system\"}}'" "controller kind"
t "R4-2: KN_CONTROLLER_KINDS=zz does not lift it either"          refuse "KN_CONTROLLER_KINDS=zz kn x-old patch ks x --type merge -p '{}'" "controller kind"
t "R4-2: KN_CONTROLLER_KINDS=' ' does not lift it"                refuse "KN_CONTROLLER_KINDS=' ' kn x-old patch hr x --type merge -p '{}'" "controller kind"
t "R4-2: annotate ks with the knob empty"                         refuse "KN_CONTROLLER_KINDS='' kn x-old annotate ks x a=b" "controller kind"
t "R4-2: the knob ADDS a kind (pvc becomes read/delete only)"     refuse "KN_CONTROLLER_KINDS='pvc' kn x-old patch pvc x -p '{}'" "controller kind"
t "R4-2: ... and the added kind can still be read and deleted"    ok     "KN_CONTROLLER_KINDS='pvc' kn x-old delete pvc x"
t "R4-2: the built-ins are still controller kinds when the knob adds another" refuse "KN_CONTROLLER_KINDS='pvc' kn x-old patch ks x --type merge -p '{}'" "controller kind"
for k in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io externalsecrets.external-secrets.io; do
  t "D1: qualified $k is refused by default (not on the allow-list)" refuse "kn x-old get $k" "kind ["
  t "D1: qualified $k added via KN_KINDS is still read/delete only" refuse "KN_KINDS='$k pod' kn x-old patch $k x --type merge -p '{}'" "controller kind"
  t "D1: qualified $k added via KN_KINDS can be read" ok "KN_KINDS='$k pod' kn x-old get $k"
done
t "D1: patching a pvc / rs stays allowed"             ok     "kn x-old patch pvc x -p '{}'"
echo "== what the pin-fix plan actually runs must still pass =="
t "get ks,hr,pod,pvc,rs,rd"                          ok 'kn x-old get ks,hr,pod,pvc,replicationsource.volsync.backube,replicationdestination.volsync.backube'
t "get pvc -o json"                                  ok 'kn x-old get pvc moveprobe2 -o json'
t "get pvc --show-managed-fields -o json"            ok 'kn x-old get pvc moveprobe2 --show-managed-fields -o json'
t "get pvc -o jsonpath (separate value)"             ok "kn x-old get pvc moveprobe2 -o jsonpath='{.status.phase}'"
t "get -ojson exact form"                            ok 'kn x-old get pods -ojson'
t "get pod -l selector"                              ok 'kn x-old get pod -l app.kubernetes.io/name=moveprobe2 -o json'
t "get events --field-selector … -o json"            ok 'kn x-old get events --field-selector involvedObject.name=moveprobe2 -o json'
t "get events --sort-by="                            ok 'kn x-old get events --sort-by=.lastTimestamp'
t "scale deploy/x --replicas=0"                      ok 'kn x-old scale deploy/moveprobe2 --replicas=0'
t "wait --for=delete pod -l … --timeout="            ok 'kn x-old wait --for=delete pod -l app.kubernetes.io/name=moveprobe2 --timeout=120s'
t "patch pvc -p JSON"                                ok "kn x-old patch pvc moveprobe2 -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"2Gi\"}}}}'"
t "patch rs --type merge -p"                         ok "kn x-old patch replicationsource.volsync.backube r --type merge -p '{\"spec\":{}}'"
t "annotate pvc key/with/slash=value"                ok 'kn x-old annotate pvc moveprobe2 kustomize.toolkit.fluxcd.io/prune=disabled'
t "delete pvc --wait=true --timeout="                ok 'kn x-old delete pvc moveprobe2 --wait=true --timeout=120s'
t "delete job --cascade=foreground --wait=false"     ok 'kn x-old delete job j --cascade=foreground --wait=false'
t "delete ks moveprobe2"                             ok 'kn x-old delete ks moveprobe2 --wait=true --timeout=300s'
t "delete rd"                                        ok 'kn x-old delete replicationdestination.volsync.backube d --wait=true --timeout=120s'
t "delete pod -l"                                    ok 'kn x-old delete pod -l app.kubernetes.io/name=moveprobe2 --wait=true'
t "logs job/x"                                       ok 'kn x-old logs job/ro-1'
t "get volumesnapshot -o jsonpath"                   ok "kn x-old get volumesnapshot vs1 -o jsonpath='{.status.x}'"
t "a -p value that starts with a dash is a VALUE"    ok "kn x-old patch pvc x -p '-nfoo'"
echo
echo "KN-GUARD TESTS: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ -z "$FAILED" ] || echo "FAILED:$FAILED" | tr '|' '\n' | sed 's/^/  /'
exit "$fail"
