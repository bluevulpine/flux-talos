#!/bin/bash
# kn-guard.sh — a REUSABLE, SELF-CONTAINED namespace-pinned kubectl wrapper: a verb + kind + FLAG allow-list, with a real JSON parse for `apply -f -`.
# Definitions only: no cluster call happens at source time. Written for bash 3.2 (/bin/bash on macOS). Vendor this one file unchanged; configure it through the
# KN_* opt-ins below. Dependencies: kubectl; for `apply -f -` ONLY: jq — if it is missing, apply is refused.
#
# WHY: pinning `-n <ns>` is NOT a namespace boundary. kubectl (pflag) takes the LAST -n, accepts COMBINED short flags (-RA, -Rnkube-system, -pnkube-system,
# -shttps://…) and attached values (-A=true), decides PER SUBCOMMAND whether a short flag takes a value (`-p` is a value in `patch` but a boolean in `logs`), normalises
# `_` to `-` in long flags, and cluster-scoped kinds ignore -n entirely. A deny-list of exact tokens loses to every one of those, so flags are an ALLOW-LIST here:
# anything not listed exactly is refused, and the refusal is the default.
#
# INTERFACE — the ONLY knobs (set BEFORE calling kn; read at call time; empty KN_NAMESPACES ⇒ every call is refused, fail closed):
#   KN_NAMESPACES="a b"        the ONLY namespaces kn may address
#   KN_KINDS="…"               optional: REPLACES the default kind allow-list (space separated, lower case)
#   KN_VERBS="…"               optional: REPLACES the default verb allow-list. Verbs outside the DEFAULT list get NO short flags at all (their arity is unknown)
#   KN_APPLY_KINDS="batch/v1/Job"   optional: the `<apiVersion>/<Kind>` pairs `kn <ns> apply -f -` may carry (default: batch/v1/Job; core kinds: v1/ConfigMap). Entries without
#                              a `/` make apply refuse (fail closed)
#   KN_CONTROLLER_KINDS="…"    optional: kinds that may be READ and DELETED but never patched/applied/annotated/labelled/scaled (default: the Flux + ESO kinds, see D1)
#   KN_EXTRA_BOOL_FLAGS=""     optional: extra long flags to allow, e.g. "--all". They are consulted AFTER every built-in list (so they can never downgrade a value flag)
#                              and are accepted ONLY as `--flag=value` (e.g. `--all=true`), because kn cannot know whether an unknown flag consumes the next token
#   KN_KUBECONFIG_PIN=""       optional: if set, kn refuses unless $KUBECONFIG equals it
#   The deny lists, the allow lists and the hard-deny verbs are NOT variables: they live inside function bodies, so no caller assignment (even a per-call prefix such as
#   `KN_HARD_DENY_VERBS="" kn …`) can blank or replace them. Nothing above can remove a hard-deny verb or a named-deny flag.
#   usage: kn <ns> <verb> <kind|kind/name …> [allow-listed flags]
#
# WHAT IS REFUSED (default deny):
#   * a namespace outside KN_NAMESPACES;
#   * a verb outside the allow-list, and ALWAYS: exec cp port-forward debug proxy attach auth run create edit replace config plugin;
#   * any flag not on the exact allow-lists below — checked AFTER the named-deny list, which always wins, and after `_` → `-` normalisation (so --all_namespaces is
#     --all-namespaces). In particular EVERY single-dash token longer than 2 characters (combined short flags such as -RA, attached values such as -Rnkube-system /
#     -pnkube-system / -shttps://… / -A=true / -n=x) except -ojson/-oyaml/-oname/-owide; a lone `-` (except as the value of `apply -f`); `--`; and every long flag not listed —
#     including, by name and in any `--flag=value` form, -n/--namespace/-A/--all-namespaces/--context/--cluster/--user/--kubeconfig/-s/--server/--as/--as-group/--as-uid/
#     --as-user-extra/--token/--raw/--insecure-skip-tls-verify/--tls-server-name/--certificate-authority/--client-*/--proxy-url/--cache-dir/--kuberc/--username/--password/
#     --filename/--kustomize/--recursive;
#   * an environment override that redirects kubectl: KUBERNETES_MASTER set (and KUBECONFIG ≠ KN_KUBECONFIG_PIN when a pin is set). kubectl itself is always run with
#     KUBERC=off KUBECTL_KUBERC=false, because a kuberc file can inject default flags (context/server/as) that are absent from argv;
#   * a resource kind outside the allow-list (so pv, ns, node, crd, clusterrole, *.longhorn.io, storageclass, volumesnapshotcontent and SECRETS are refused), checked on
#     the first positional and on every positional containing `/` or `,` (each comma element, kind part before the `/`). Empty positionals and positionals starting with `=`
#     are refused; a positional containing `=` is refused EXCEPT `key=value` / `key-` pairs of `annotate`/`label` that come AFTER a resource positional (kubectl's own rule);
#   * `apply` unless it is `apply -f -`. The manifest must be JSON (YAML is refused: YAML 1.1 vs 1.2 scalar rules — 0400, yes/on — differ between kubectl and any YAML
#     parser here, so a parsed YAML manifest would not mean what kubectl reads). jq PARSES it, EVERY document (a stream is allowed) must be an object whose
#     `apiVersion/kind` is in KN_APPLY_KINDS, with no key spelled like `items` (kubectl treats ANY object with a top-level `items` key as a LIST and applies each item, whatever
#     the root kind says), no two root keys that differ only in case (so no case-variant of kind/apiVersion/items can shadow the exact ones), and no key spelled like `namespace` anywhere; kubectl is sent the CANONICAL `jq -c` form that
#     was checked — never the original bytes. Refusal messages never echo manifest content (it may be a Secret's stringData);
#   * on delete/patch/annotate/label/scale/apply, a selector (-l/--selector/--field-selector) that is not plain equality terms `k=v[,k=v…]`: `x!=y`, `notin`, `!x` and
#     `k` alone match (almost) everything and are the same as `--all`, which is itself refused.
#
# ALLOWED FLAGS
#   short, per verb         -l (every default verb) · -o (get delete patch apply annotate label scale wait) · -p (`patch`: takes a value; `logs`: BOOLEAN --previous)
#                           · -c (`logs`) · -f (`apply -f -` only). The value-taking short flags consume the next token; the boolean one does not.
#   short, exact            -ojson -oyaml -oname -owide
#   long, boolean           --wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps
#   long, value may follow  --output --selector --patch --type --field-selector --container      (`--flag value` or `--flag=value`; with `=` nothing is consumed)
#   long, `=` REQUIRED      --timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run  + every KN_EXTRA_BOOL_FLAGS entry
#                           (their separate-value semantics differ per kubectl subcommand — cascade/dry-run take NO separate value — so the space form is refused rather than guessed)
#
# DESIGN NOTES (what the namespace pin does NOT contain)
#   D1. The kinds `ks kustomization hr helmrelease ocirepository externalsecret` (and their qualified names) ARE on the default allow-list (a caller managing a Flux app
#       needs to read and delete them) but they are instructions to cluster-admin controllers: patching a Kustomization's `targetNamespace`, or deleting one with `prune: true`
#       (it garbage-collects its whole inventory), or an ExternalSecret pulling any secret-store key, acts OUTSIDE the pinned namespace. So kn refuses every write except
#       `delete` on them (KN_CONTROLLER_KINDS), and `delete` remains a decision of the CALLER: the namespace pin does not bound what a deleted controller object collects.
#   F6. Selectors: a selector of plain equality terms can still match every object that carries the label — and an equality FIELD selector such as
#       `metadata.namespace=<ns>` or `metadata.name=…` can match everything in the namespace, the same as `--all`. That is the caller's scoping; kn cannot judge it.
#   The guard never inspects `-p`/`--patch` payloads: a patch to a permitted kind is whatever the caller says it is.

# _kn_L <name>: the built-in lists. Functions, not variables: a caller cannot blank or replace them by assigning a KN_* / _KN_* name.
_kn_L() {
  case "$1" in
    DEFAULT_VERBS) echo "get describe logs wait scale patch delete apply annotate label";;
    HARD_DENY_VERBS) echo "exec cp port-forward debug proxy attach auth run create edit replace config plugin";;
    DEFAULT_KINDS) echo "pod pods po deploy deployment deployments job jobs pvc pvcs persistentvolumeclaim persistentvolumeclaims ks kustomization kustomizations
 hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets volumesnapshot volumesnapshots event events
 replicationsource.volsync.backube replicationdestination.volsync.backube";;
    CONTROLLER_KINDS) echo "ks kustomization kustomizations hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets
 kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io externalsecrets.external-secrets.io";;
    LONG_BOOL) echo "--wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps";;
    LONG_SEP) echo "--output --selector --patch --type --field-selector --container";;
    LONG_EQ) echo "--timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run";;
    LONG_DENY) echo "--namespace --all-namespaces --context --cluster --user --kubeconfig --server --as --as-group --as-uid --as-user-extra --token --raw --insecure-skip-tls-verify --tls-server-name --certificate-authority --username --password --filename --kustomize --recursive --proxy-url --cache-dir --kuberc";;
    MUTATE_VERBS) echo "patch apply annotate label scale";;
    SELECTOR_VERBS) echo "delete patch apply annotate label scale";;
    SELECTOR_RE) echo '^[A-Za-z0-9_./-]+==?[A-Za-z0-9_.-]+(,[A-Za-z0-9_./-]+==?[A-Za-z0-9_.-]+)*$';;
    *) echo "kn-guard: unknown list $1" >&2; return 1;;
  esac
}

# _kn_in <word> <space-separated-list>. IFS and noglob are set ONCE, by kn() below, for every helper it calls (do not call the helpers outside kn).
_kn_in() { local w=$1 x; for x in $2; do [ "$x" = "$w" ] && return 0; done; return 1; }
_kn_refuse() { echo "REFUSE: kn: $*" >&2; return 1; }
# _kn_short <verb> <flag>: "val" (takes the next token), "bool", or "deny" — decided PER VERB, the way kubectl does. Verbs outside the default list: deny.
_kn_short() {
  _kn_in "$1" "$(_kn_L DEFAULT_VERBS)" || { echo deny; return; }
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
  local re
  _kn_in "$1" "$(_kn_L SELECTOR_VERBS)" || return 0
  re=$(_kn_L SELECTOR_RE)
  [[ "$2" =~ $re ]] && return 0
  _kn_refuse "selector [$2] on '$1' must be plain equality terms k=v[,k=v…] (!=, notin, bare keys and negations match everything, like --all)"; return 1
}
# _kn_kinds_ok <verb> <token>: every comma element's kind part (before '/') must be on the allow-list; write verbs may not touch controller kinds.
_kn_kinds_ok() {
  local verb=$1 tok=$2 e k kinds ctl
  local -a parts
  kinds=${KN_KINDS:-$(_kn_L DEFAULT_KINDS)}; ctl=${KN_CONTROLLER_KINDS-$(_kn_L CONTROLLER_KINDS)}
  IFS=, read -r -a parts <<<"$tok"
  for e in ${parts[@]+"${parts[@]}"}; do
    k=${e%%/*}
    _kn_in "$k" "$kinds" || { _kn_refuse "kind [$k] is not on the allow-list"; return 1; }
    if _kn_in "$verb" "$(_kn_L MUTATE_VERBS)" && _kn_in "$k" "$ctl"; then _kn_refuse "kind [$k] is a controller kind: '$verb' is refused (read/delete only; see D1)"; return 1; fi
  done
}
# _kn_apply_canon <apiVersion/Kind list>: manifest on stdin -> canonical `jq -c` stream on stdout, or a refusal. JSON only; EVERY document is checked; no content is echoed.
_kn_apply_canon() {
  local IFS=$' \t\n' raw canon e
  if ! command -v jq >/dev/null 2>&1; then _kn_refuse "apply needs jq to parse the manifest; refusing"; return 1; fi
  for e in $1; do case "$e" in */?*) ;; *) _kn_refuse "KN_APPLY_KINDS entry [$e] must be <apiVersion>/<Kind> (for example batch/v1/Job)"; return 1;; esac; done
  raw=$(cat)
  canon=$(printf '%s\n' "$raw" | jq -c '.' 2>/dev/null) || { _kn_refuse "apply: the manifest is not valid JSON (YAML is refused: its scalar rules differ between kubectl and any parser here)"; return 1; }
  [ -n "$canon" ] || { _kn_refuse "apply: no document in the manifest"; return 1; }
  printf '%s\n' "$canon" | jq -e -s --arg allowed "$1" '
      ($allowed | split(" ") | map(select(length > 0))) as $ok
      | length >= 1
      and all(.[];
          type == "object"
          and ((.kind | type) == "string") and ((.apiVersion | type) == "string")
          and (((.apiVersion + "/" + .kind)) as $av | ($ok | index($av)) != null)
          and (([keys[] | ascii_downcase] | index("items")) == null)
          and (([keys[] | ascii_downcase] | length) == ([keys[] | ascii_downcase] | unique | length))
          and (([.. | objects | keys[] | ascii_downcase | select(. == "namespace")] | length) == 0))' >/dev/null 2>&1 \
    || { _kn_refuse "apply: every JSON document must be an object with an apiVersion/kind in [$1], no key spelled like items or namespace, and no two root keys differing only in case"; return 1; }
  printf '%s\n' "$canon"
}

# kn: wraps the real work so the caller's IFS and pathname expansion can never change how the arguments are classified, and restores the caller's `set -f`.
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
  verbs=${KN_VERBS:-$(_kn_L DEFAULT_VERBS)}; applykinds=${KN_APPLY_KINDS:-batch/v1/Job}
  verb=${1:-}; shift
  if _kn_in "$verb" "$(_kn_L HARD_DENY_VERBS)"; then _kn_refuse "verb [$verb] is never allowed"; return 1; fi
  _kn_in "$verb" "$verbs" || { _kn_refuse "verb [$verb] is not on the allow-list ($verbs)"; return 1; }
  # Walk the arguments EXACTLY as kubectl would, and refuse anything that is not on an allow-list.
  local i=0 n=$#
  local rest=("$@")
  while [ "$i" -lt "$n" ]; do
    a=${rest[$i]}; i=$((i + 1))
    case "$a" in
      --) _kn_refuse "'--' is not accepted"; return 1;;
      --*)
        name=${a%%=*}; name=${name//_/-}; hasval=0; case "$a" in *=*) hasval=1;; esac      # kubectl normalises _ to - in long flag names
        # the named-deny list is checked FIRST, so no configuration can re-enable one of these
        if _kn_in "$name" "$(_kn_L LONG_DENY)" || case "$name" in --client-*) true;; *) false;; esac; then
          _kn_refuse "denied flag [$a] (namespace / cluster / credential / file override)"; return 1
        elif _kn_in "$name" "$(_kn_L LONG_BOOL)"; then continue
        elif _kn_in "$name" "$(_kn_L LONG_SEP)"; then
          if [ "$hasval" = 1 ]; then
            case "$name" in --selector|--field-selector) _kn_selector_ok "$verb" "${a#*=}" || return 1;; esac
          else
            [ "$i" -lt "$n" ] || { _kn_refuse "flag [$a] has no value"; return 1; }
            case "$name" in --selector|--field-selector) _kn_selector_ok "$verb" "${rest[$i]}" || return 1;; esac
            i=$((i + 1))
          fi
        elif _kn_in "$name" "$(_kn_L LONG_EQ)"; then
          [ "$hasval" = 1 ] || { _kn_refuse "flag [$a] must be written $a=<value>"; return 1; }
        elif _kn_in "$name" "${KN_EXTRA_BOOL_FLAGS:-}"; then            # consulted LAST, and only as --flag=value
          [ "$hasval" = 1 ] || { _kn_refuse "extra flag [$a] must be written $a=<value> (kn cannot know whether an unlisted flag consumes the next token)"; return 1; }
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
      ''|=*) _kn_refuse "positional [$a] is empty or starts with '='"; return 1;;
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
    printf '%s\n' "$canon" | env KUBERC=off KUBECTL_KUBERC=false kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
    return
  fi
  env KUBERC=off KUBECTL_KUBERC=false kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
}
