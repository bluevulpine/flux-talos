#!/bin/bash
# kn-guard.sh — a REUSABLE, SELF-CONTAINED namespace-pinned kubectl wrapper: a verb + kind + FLAG allow-list, with a real YAML parse for `apply -f -`.
# Definitions only: no cluster call happens at source time. Written for bash 3.2 (/bin/bash on macOS). Vendor this one file unchanged; configure it through the
# variables below. Dependencies: kubectl; for `apply -f -` ONLY: yq (mikefarah v4) and jq — if either is missing, apply is refused.
#
# WHY: pinning `-n <ns>` is NOT a namespace boundary. kubectl (pflag) takes the LAST -n, accepts COMBINED short flags (-RA, -Rnkube-system, -pnkube-system,
# -shttps://…) and attached values (-A=true), decides PER SUBCOMMAND whether a short flag takes a value (`-p` is a value in `patch` but a boolean in `logs`), and
# cluster-scoped kinds ignore -n entirely. A deny-list of exact tokens loses to every one of those, so flags are an ALLOW-LIST here: anything not listed exactly is
# refused, and the refusal is the default.
#
# INTERFACE (set BEFORE calling kn; read at call time; empty KN_NAMESPACES ⇒ every call is refused, fail closed):
#   KN_NAMESPACES="a b"        the ONLY namespaces kn may address
#   KN_KINDS="…"               optional: REPLACES the default kind allow-list (space separated, lower case)
#   KN_VERBS="…"               optional: REPLACES the default verb allow-list. Verbs outside the DEFAULT list get NO short flags at all (their arity is unknown);
#                              the hard-deny verbs below can never be re-enabled
#   KN_APPLY_KINDS="Job"       optional: the manifest kinds `kn <ns> apply -f -` may carry (default: Job)
#   KN_CONTROLLER_KINDS="…"    optional: kinds that may be READ and DELETED but never patched/applied/annotated/labelled/scaled (default: the Flux + ESO kinds, see D1)
#   KN_EXTRA_BOOL_FLAGS=""     optional: extra long boolean flags to allow, e.g. "--all". A flag on the named-deny list below can NOT be re-enabled this way
#   KN_KUBECONFIG_PIN=""       optional: if set, kn refuses unless $KUBECONFIG equals it
#   usage: kn <ns> <verb> <kind|kind/name …> [allow-listed flags]
#
# WHAT IS REFUSED (default deny):
#   * a namespace outside KN_NAMESPACES;
#   * a verb outside the allow-list, and ALWAYS: exec cp port-forward debug proxy attach auth run create edit replace config plugin;
#   * any flag not on the exact allow-lists below — checked AFTER the named-deny list, which always wins. In particular EVERY single-dash token longer than 2 characters
#     (combined short flags such as -RA, attached values such as -Rnkube-system / -pnkube-system / -shttps://… / -A=true / -n=x) except -ojson/-oyaml/-oname/-owide;
#     a lone `-` (except as the value of `apply -f`); `--`; and every long flag not listed — including, by name and in any `--flag=value` form,
#     -n/--namespace/-A/--all-namespaces/--context/--cluster/--user/--kubeconfig/-s/--server/--as/--as-group/--as-uid/--token/--raw/--insecure-skip-tls-verify/
#     --tls-server-name/--certificate-authority/--client-*/--username/--password/--filename/--kustomize/--recursive;
#   * an environment override that redirects kubectl: KUBERNETES_MASTER set (and KUBECONFIG ≠ KN_KUBECONFIG_PIN when a pin is set). kubectl itself is always run with
#     KUBERC=off KUBECTL_KUBERC=false, because a kuberc file can inject default flags (context/server/as) that are absent from argv;
#   * a resource kind outside the allow-list (so pv, ns, node, crd, clusterrole, *.longhorn.io, storageclass, volumesnapshotcontent and SECRETS are refused), checked on
#     the first positional and on every positional containing `/` or `,` (each comma element, kind part before the `/`). A positional containing `=` is refused,
#     EXCEPT `key=value` / `key-` pairs of `annotate`/`label` that come AFTER a resource positional (kubectl's own rule) — the rest of the line is then pairs;
#   * `apply` unless it is `apply -f -`. The manifest is PARSED (yq → JSON), EVERY document must be an object whose .kind is in KN_APPLY_KINDS, with an apiVersion and no
#     key named `namespace` anywhere, and kubectl is sent the CANONICAL JSON that was checked — never the original bytes. This closes quoting, flow style, aliases,
#     !!str tags, merge keys, escaped and quoted keys, multi-line scalars and multi-document tricks at once;
#   * on delete/patch/annotate/label/scale/apply, a selector (-l/--selector/--field-selector) that is not plain equality terms `k=v[,k=v…]`: `x!=y`, `notin`, `!x` and
#     `k` alone match (almost) everything and are the same as `--all`, which is itself refused.
#
# ALLOWED FLAGS
#   short, per verb         -l (every default verb) · -o (get delete patch apply annotate label scale wait) · -p (`patch`: takes a value; `logs`: BOOLEAN --previous)
#                           · -c (`logs`) · -f (`apply -f -` only). The value-taking short flags consume the next token; the boolean one does not.
#   short, exact            -ojson -oyaml -oname -owide
#   long, boolean           --wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps  (+ KN_EXTRA_BOOL_FLAGS)
#   long, value may follow  --output --selector --patch --type --field-selector --container      (`--flag value` or `--flag=value`; with `=` nothing is consumed)
#   long, `=` REQUIRED      --timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run
#                           (their separate-value semantics differ per kubectl subcommand — cascade/dry-run take NO separate value — so the space form is refused
#                            rather than guessed)
#
# DESIGN NOTES (what the namespace pin does NOT contain)
#   D1. The kinds `ks kustomization hr helmrelease ocirepository externalsecret` ARE on the default allow-list (a caller managing a Flux app needs to read and delete
#       them) but they are instructions to cluster-admin controllers: patching a Kustomization's `targetNamespace`, or deleting one with `prune: true` (it garbage-collects
#       its whole inventory), or an ExternalSecret pulling any secret-store key, acts OUTSIDE the pinned namespace. So kn refuses every write except `delete` on them
#       (KN_CONTROLLER_KINDS), and `delete` remains a decision of the CALLER: the namespace pin does not bound what a deleted controller object garbage-collects.
#   F6. Selectors: see the last refusal above. A selector of plain equality terms can still match every object that carries the label; that is the caller's scoping.
#   The guard never inspects `-p`/`--patch` payloads: a patch to a permitted kind is whatever the caller says it is.

KN_DEFAULT_VERBS="get describe logs wait scale patch delete apply annotate label"
KN_HARD_DENY_VERBS="exec cp port-forward debug proxy attach auth run create edit replace config plugin"
KN_DEFAULT_KINDS="pod pods po deploy deployment deployments job jobs pvc pvcs persistentvolumeclaim persistentvolumeclaims ks kustomization kustomizations
 hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets volumesnapshot volumesnapshots event events
 replicationsource.volsync.backube replicationdestination.volsync.backube"
KN_DEFAULT_CONTROLLER_KINDS="ks kustomization kustomizations hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets"
KN_LONG_BOOL="--wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps"
KN_LONG_SEP="--output --selector --patch --type --field-selector --container"
KN_LONG_EQ="--timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run"
KN_LONG_DENY="--namespace --all-namespaces --context --cluster --user --kubeconfig --server --as --as-group --as-uid --token --raw --insecure-skip-tls-verify --tls-server-name --certificate-authority --username --password --filename --kustomize --recursive"
KN_MUTATE_VERBS="patch apply annotate label scale"
KN_SELECTOR_VERBS="delete patch apply annotate label scale"
KN_SELECTOR_RE='^[A-Za-z0-9_./-]+==?[A-Za-z0-9_.-]+(,[A-Za-z0-9_./-]+==?[A-Za-z0-9_.-]+)*$'

# _kn_in <word> <space-separated-list>  (never depends on the caller's IFS)
_kn_in() { local IFS=$' \t\n' w=$1 x; for x in $2; do [ "$x" = "$w" ] && return 0; done; return 1; }
_kn_refuse() { echo "REFUSE: kn: $*" >&2; return 1; }
# _kn_short <verb> <flag>: "val" (takes the next token), "bool", or "deny" — decided PER VERB, the way kubectl does. Verbs outside the default list: deny.
_kn_short() {
  _kn_in "$1" "$KN_DEFAULT_VERBS" || { echo deny; return; }
  case "$2" in
    -l) echo val;;
    -o) case "$1" in get|delete|patch|apply|annotate|label|scale|wait) echo val;; *) echo deny;; esac;;
    -p) case "$1" in patch) echo val;; logs) echo bool;; *) echo deny;; esac;;
    -c) case "$1" in logs) echo val;; *) echo deny;; esac;;
    *) echo deny;;
  esac
}
# _kn_selector_ok <verb> <value>: selectors on write verbs must be plain equality terms.
_kn_selector_ok() {
  _kn_in "$1" "$KN_SELECTOR_VERBS" || return 0
  [[ "$2" =~ $KN_SELECTOR_RE ]] && return 0
  _kn_refuse "selector [$2] on '$1' must be plain equality terms k=v[,k=v…] (!=, notin, bare keys and negations match everything, like --all)"; return 1
}
# _kn_kinds_ok <verb> <token> [first]: every comma element's kind part (before '/') must be on the allow-list; write verbs may not touch controller kinds.
_kn_kinds_ok() {
  local IFS=, verb=$1 tok=$2 e k kinds=${KN_KINDS:-$KN_DEFAULT_KINDS} ctl=${KN_CONTROLLER_KINDS-$KN_DEFAULT_CONTROLLER_KINDS}
  local -a parts
  read -r -a parts <<<"$tok"
  for e in ${parts[@]+"${parts[@]}"}; do
    k=${e%%/*}
    _kn_in "$k" "$kinds" || { _kn_refuse "kind [$k] is not on the allow-list"; return 1; }
    if _kn_in "$verb" "$KN_MUTATE_VERBS" && _kn_in "$k" "$ctl"; then _kn_refuse "kind [$k] is a controller kind: '$verb' is refused (read/delete only; see D1)"; return 1; fi
  done
}
# _kn_apply_canon <apply-kinds>: manifest on stdin -> canonical NDJSON on stdout, or a refusal. A REAL parse; every document is checked.
_kn_apply_canon() {
  local IFS=$' \t\n' raw canon line out="" n=0 selftest
  if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then _kn_refuse "apply needs yq and jq to parse the manifest; refusing"; return 1; fi
  selftest=$(printf 'a: 1\n' | yq -o=json -I=0 'explode(.)' 2>/dev/null) || selftest=""
  [ "$selftest" = '{"a":1}' ] || { _kn_refuse "apply: yq is not mikefarah yq v4 (self-test failed); refusing"; return 1; }
  raw=$(cat)
  canon=$(printf '%s\n' "$raw" | yq -o=json -I=0 'explode(.)' 2>/dev/null) || { _kn_refuse "apply: the manifest does not parse as YAML"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = null ] && continue                          # an empty document: kubectl skips it too
    jq -e --arg kinds "$1" '
        type == "object"
        and ((.kind | type) == "string") and ((.apiVersion | type) == "string")
        and ((.kind) as $k | ($kinds | split(" ") | index($k)) != null)
        and (([.. | objects | has("namespace")] | any) | not)' <<<"$line" >/dev/null 2>&1 \
      || { _kn_refuse "apply: a document is not an object of kind [$1] with an apiVersion and no namespace key (document: $(head -c 120 <<<"$line"))"; return 1; }
    n=$((n + 1)); out="$out$line"$'\n'
  done <<<"$canon"
  [ "$n" -ge 1 ] || { _kn_refuse "apply: no document in the manifest"; return 1; }
  printf '%s' "$out"
}

# kn: wraps the real work so the caller's IFS and pathname expansion can never change how the arguments are classified (F4), and restores the caller's `set -f`.
kn() {
  local _kn_opts=$- _kn_rc IFS=$' \t\n'
  set -f
  _kn_main "$@"; _kn_rc=$?
  case $_kn_opts in *f*) ;; *) set +f;; esac
  return "$_kn_rc"
}

_kn_main() {
  local ns=${1:-} verb a name hasval verbs applykinds first=1 apply_stdin=0 pairs=0 arity canon
  [ $# -ge 2 ] || { echo "usage: kn <ns> <verb> <kind> …" >&2; return 1; }
  shift
  _kn_in "$ns" "${KN_NAMESPACES:-}" || { echo "REFUSE ns=[$ns] (allowed: [${KN_NAMESPACES:-}])" >&2; return 1; }
  [ -z "${KUBERNETES_MASTER:-}" ] || { _kn_refuse "KUBERNETES_MASTER is set (it redirects kubectl to another API server)"; return 1; }
  if [ -n "${KN_KUBECONFIG_PIN:-}" ] && [ "${KUBECONFIG:-}" != "$KN_KUBECONFIG_PIN" ]; then _kn_refuse "KUBECONFIG [${KUBECONFIG:-}] != the pinned [$KN_KUBECONFIG_PIN]"; return 1; fi
  verbs=${KN_VERBS:-$KN_DEFAULT_VERBS}; applykinds=${KN_APPLY_KINDS:-Job}
  verb=${1:-}; shift
  if _kn_in "$verb" "$KN_HARD_DENY_VERBS"; then _kn_refuse "verb [$verb] is never allowed"; return 1; fi
  _kn_in "$verb" "$verbs" || { _kn_refuse "verb [$verb] is not on the allow-list ($verbs)"; return 1; }
  # Walk the arguments EXACTLY as kubectl would, and refuse anything that is not on an allow-list.
  local i=0 n=$#
  local rest=("$@")
  while [ "$i" -lt "$n" ]; do
    a=${rest[$i]}; i=$((i + 1))
    case "$a" in
      --) _kn_refuse "'--' is not accepted"; return 1;;
      --*)
        name=${a%%=*}; hasval=0; case "$a" in *=*) hasval=1;; esac
        # the named-deny list is checked FIRST, so no configuration can re-enable one of these (F5)
        if _kn_in "$name" "$KN_LONG_DENY" || case "$name" in --client-*) true;; *) false;; esac; then
          _kn_refuse "denied flag [$a] (namespace / cluster / credential / file override)"; return 1
        elif _kn_in "$name" "$KN_LONG_BOOL ${KN_EXTRA_BOOL_FLAGS:-}"; then continue
        elif _kn_in "$name" "$KN_LONG_SEP"; then
          if [ "$hasval" = 1 ]; then
            case "$name" in --selector|--field-selector) _kn_selector_ok "$verb" "${a#*=}" || return 1;; esac
          else
            [ "$i" -lt "$n" ] || { _kn_refuse "flag [$a] has no value"; return 1; }
            case "$name" in --selector|--field-selector) _kn_selector_ok "$verb" "${rest[$i]}" || return 1;; esac
            i=$((i + 1))
          fi
        elif _kn_in "$name" "$KN_LONG_EQ"; then
          [ "$hasval" = 1 ] || { _kn_refuse "flag [$a] must be written $a=<value>"; return 1; }
        else
          _kn_refuse "flag [$a] is not on the allow-list"; return 1
        fi;;
      -f)
        [ "$verb" = apply ] || { _kn_refuse "-f is only accepted as 'apply -f -'"; return 1; }
        [ "$i" -lt "$n" ] && [ "${rest[$i]}" = "-" ] || { _kn_refuse "-f accepts only '-' (stdin)"; return 1; }
        i=$((i + 1)); apply_stdin=1;;
      -ojson|-oyaml|-oname|-owide) ;;
      -?)
        arity=$(_kn_short "$verb" "$a")
        case "$arity" in
          val)
            [ "$i" -lt "$n" ] || { _kn_refuse "flag [$a] has no value"; return 1; }
            [ "$a" = -l ] && { _kn_selector_ok "$verb" "${rest[$i]}" || return 1; }
            i=$((i + 1));;
          bool) ;;
          *) _kn_refuse "short flag [$a] is not allowed for '$verb'"; return 1;;
        esac;;
      -*) _kn_refuse "flag [$a] is not on the allow-list (single-dash tokens longer than 2 characters — combined short flags such as -RA, attached values such as -Rnkube-system / -shttps://… / -A=true — are refused)"; return 1;;
      *)
        if [ "$pairs" = 1 ]; then continue; fi                       # annotate/label pairs: everything after the first pair is a pair (kubectl's rule)
        case "$a" in
          *=*|*-)
            if { [ "$verb" = annotate ] || [ "$verb" = label ]; } && [ "$first" = 0 ]; then pairs=1; continue; fi
            case "$a" in
              *=*) _kn_refuse "positional [$a] contains '=' (only annotate/label key=value pairs after a resource are accepted)"; return 1;;
            esac;;
        esac
        if [ "$first" = 1 ]; then
          first=0
          _kn_kinds_ok "$verb" "$a" || return 1
        else
          case "$a" in */*|*,*) _kn_kinds_ok "$verb" "$a" || return 1;; esac
        fi;;
    esac
  done
  if [ "$verb" = apply ]; then
    [ "$apply_stdin" = 1 ] || { _kn_refuse "apply needs -f -"; return 1; }
    canon=$(_kn_apply_canon "$applykinds") || return 1
    printf '%s' "$canon" | env KUBERC=off KUBECTL_KUBERC=false kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
    return
  fi
  env KUBERC=off KUBECTL_KUBERC=false kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
}
