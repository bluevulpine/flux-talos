#!/bin/bash
# kn-guard.sh — a REUSABLE, SELF-CONTAINED namespace-pinned kubectl wrapper: a verb + kind + FLAG allow-list. Definitions only: no cluster call happens at source time.
# Written for bash 3.2 (/bin/bash on macOS). Vendor this one file unchanged; configure it through the variables below.
#
# WHY: pinning `-n <ns>` is NOT a namespace boundary. kubectl (pflag) takes the LAST -n, accepts COMBINED short flags (-RA, -Rnkube-system, -pnkube-system,
# -shttps://…) and attached values (-A=true), and cluster-scoped kinds ignore -n entirely. A deny-list of exact tokens loses to every one of those, so
# flags are an ALLOW-LIST here: anything not listed exactly is refused, and the refusal is the default.
#
# INTERFACE (set BEFORE calling kn; read at call time; empty KN_NAMESPACES ⇒ every call is refused, fail closed):
#   KN_NAMESPACES="a b"      the ONLY namespaces kn may address
#   KN_KINDS="…"             optional: REPLACES the default kind allow-list (space separated, lower case)
#   KN_VERBS="…"             optional: REPLACES the default verb allow-list (the hard-deny verbs below can never be re-enabled)
#   KN_APPLY_KINDS="Job"     optional: the manifest kinds `kn <ns> apply -f -` may carry (default: Job)
#   KN_EXTRA_BOOL_FLAGS=""   optional: extra long boolean flags to allow, e.g. "--all" (default: none)
#   KN_KUBECONFIG_PIN=""     optional: if set, kn refuses unless $KUBECONFIG equals it
#   usage: kn <ns> <verb> <kind|kind/name …> [allow-listed flags]
#
# WHAT IS REFUSED (default deny):
#   * a namespace outside KN_NAMESPACES;
#   * a verb outside the allow-list, and ALWAYS (even if KN_VERBS lists them): exec cp port-forward debug proxy attach auth run create edit replace config plugin;
#   * any flag not on the exact allow-lists below. In particular EVERY single-dash token longer than 2 characters (combined short flags such as -RA, attached values
#     such as -Rnkube-system, -pnkube-system, -shttps://…, -A=true, -n=x) except -ojson/-oyaml/-oname/-owide; a lone `-` (except as the value of `apply -f`); `--`;
#     and every long flag not listed — including, by name, -n/--namespace/-A/--all-namespaces/--context/--cluster/--user/--kubeconfig/-s/--server/--as/--as-group/
#     --as-uid/--token/--raw/--insecure-skip-tls-verify/--tls-server-name/--certificate-authority/--client-*/--username/--password, in any `--flag=value` form;
#   * an environment override that redirects kubectl: KUBERNETES_MASTER set (and KUBECONFIG ≠ KN_KUBECONFIG_PIN when a pin is set);
#   * a resource kind outside the allow-list (so pv, ns, node, crd, clusterrole, *.longhorn.io, storageclass, volumesnapshotcontent and SECRETS are refused), checked on the
#     first positional (comma-split) and on every kind/name positional; `key=value` positionals (annotate/label assignments) are not kinds;
#   * `apply` unless it is `apply -f -`, and then only when stdin has no namespace, no JSON form, and EVERY `kind:` anywhere in it is in KN_APPLY_KINDS.
#
# ALLOWED FLAGS
#   short, separate value   -o -l -p -c            (`-f` only as `apply -f -`)
#   short, exact            -ojson -oyaml -oname -owide
#   long, boolean           --wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps  (+ KN_EXTRA_BOOL_FLAGS)
#   long, value may follow  --output --selector --patch --type --field-selector --container      (`--flag value` or `--flag=value`)
#   long, `=` REQUIRED      --timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run
#                           (their separate-value semantics differ per kubectl subcommand — cascade/dry-run take NO separate value — so the space form is refused
#                            rather than guessed: guessing wrong would let the next token be read as a value while kubectl reads it as a flag)

KN_DEFAULT_VERBS="get describe logs wait scale patch delete apply annotate label"
KN_HARD_DENY_VERBS="exec cp port-forward debug proxy attach auth run create edit replace config plugin"
KN_DEFAULT_KINDS="pod pods po deploy deployment deployments job jobs pvc pvcs persistentvolumeclaim persistentvolumeclaims ks kustomization kustomizations
 hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets volumesnapshot volumesnapshots event events
 replicationsource.volsync.backube replicationdestination.volsync.backube"
KN_LONG_BOOL="--wait --show-managed-fields --no-headers --ignore-not-found --overwrite --previous --show-labels --timestamps"
KN_LONG_SEP="--output --selector --patch --type --field-selector --container"
KN_LONG_EQ="--timeout --sort-by --tail --since --limit-bytes --for --replicas --cascade --grace-period --dry-run"

# _kn_in <word> <space-separated-list>
_kn_in() { local w=$1 x; for x in $2; do [ "$x" = "$w" ] && return 0; done; return 1; }
_kn_refuse() { echo "REFUSE: kn: $*" >&2; return 1; }

kn() {
  local ns=${1:-} verb a name hasval kinds verbs applykinds first=1 apply_stdin=0 k tok stdin_yaml kk
  [ $# -ge 2 ] || { echo "usage: kn <ns> <verb> <kind> …" >&2; return 1; }
  shift
  _kn_in "$ns" "${KN_NAMESPACES:-}" || { echo "REFUSE ns=[$ns] (allowed: [${KN_NAMESPACES:-}])" >&2; return 1; }
  [ -z "${KUBERNETES_MASTER:-}" ] || { _kn_refuse "KUBERNETES_MASTER is set (it redirects kubectl to another API server)"; return 1; }
  if [ -n "${KN_KUBECONFIG_PIN:-}" ] && [ "${KUBECONFIG:-}" != "$KN_KUBECONFIG_PIN" ]; then _kn_refuse "KUBECONFIG [${KUBECONFIG:-}] != the pinned [$KN_KUBECONFIG_PIN]"; return 1; fi
  verbs=${KN_VERBS:-$KN_DEFAULT_VERBS}; kinds=${KN_KINDS:-$KN_DEFAULT_KINDS}; applykinds=${KN_APPLY_KINDS:-Job}
  verb=${1:-}; shift
  if _kn_in "$verb" "$KN_HARD_DENY_VERBS"; then _kn_refuse "verb [$verb] is never allowed"; return 1; fi
  _kn_in "$verb" "$verbs" || { _kn_refuse "verb [$verb] is not on the allow-list ($verbs)"; return 1; }
  # Walk the arguments EXACTLY as kubectl would, and refuse anything that is not on an allow-list.
  # (Pass all "$@" through to kubectl only after the whole line has been accepted.)
  local i=0 n=$#
  local rest=("$@")
  while [ "$i" -lt "$n" ]; do
    a=${rest[$i]}; i=$((i + 1))
    case "$a" in
      --) _kn_refuse "'--' is not accepted"; return 1;;
      --*)
        name=${a%%=*}; hasval=0; case "$a" in *=*) hasval=1;; esac
        if _kn_in "$name" "$KN_LONG_BOOL ${KN_EXTRA_BOOL_FLAGS:-}"; then continue
        elif _kn_in "$name" "$KN_LONG_SEP"; then
          if [ "$hasval" = 0 ]; then [ "$i" -lt "$n" ] || { _kn_refuse "flag [$a] has no value"; return 1; }; i=$((i + 1)); fi
        elif _kn_in "$name" "$KN_LONG_EQ"; then
          [ "$hasval" = 1 ] || { _kn_refuse "flag [$a] must be written $a=<value>"; return 1; }
        else
          case "$name" in
            --namespace|--all-namespaces|--context|--cluster|--user|--kubeconfig|--server|--as|--as-group|--as-uid|--token|--raw|--insecure-skip-tls-verify|--tls-server-name|--certificate-authority|--client-*|--username|--password|--filename|--kustomize|--recursive)
              _kn_refuse "denied flag [$a] (namespace / cluster / credential / file override)"; return 1;;
          esac
          _kn_refuse "flag [$a] is not on the allow-list"; return 1
        fi;;
      -o|-l|-p|-c)
        [ "$i" -lt "$n" ] || { _kn_refuse "flag [$a] has no value"; return 1; }; i=$((i + 1));;
      -f)
        [ "$verb" = apply ] || { _kn_refuse "-f is only accepted as 'apply -f -'"; return 1; }
        [ "$i" -lt "$n" ] && [ "${rest[$i]}" = "-" ] || { _kn_refuse "-f accepts only '-' (stdin)"; return 1; }
        i=$((i + 1)); apply_stdin=1;;
      -ojson|-oyaml|-oname|-owide) ;;
      -*) _kn_refuse "flag [$a] is not on the allow-list (single-dash tokens longer than 2 characters — combined short flags such as -RA, attached values such as -Rnkube-system / -shttps://… / -A=true — and every unlisted short flag are refused)"; return 1;;
      *)
        case "$a" in *=*) continue;; esac                  # key=value (annotate/label assignment): not a kind
        if [ "$first" = 1 ]; then
          first=0
          tok=${a%%/*}
          for k in $(printf '%s' "$tok" | tr ',' ' '); do
            _kn_in "$k" "$kinds" || { _kn_refuse "kind [$k] is not on the allow-list"; return 1; }
          done
        fi
        case "$a" in */*) k=${a%%/*}; _kn_in "$k" "$kinds" || { _kn_refuse "kind [$k] (in [$a]) is not on the allow-list"; return 1; };; esac;;
    esac
  done
  if [ "$verb" = apply ]; then
    [ "$apply_stdin" = 1 ] || { _kn_refuse "apply needs -f -"; return 1; }
    stdin_yaml=$(cat)
    if grep -Eiq 'namespace["'\'']?[[:space:]]*:' <<<"$stdin_yaml"; then _kn_refuse "apply: the manifest names a namespace"; return 1; fi
    if grep -Eq '^[[:space:]]*[{[]' <<<"$stdin_yaml"; then _kn_refuse "apply: JSON manifests are not accepted (the kind check reads YAML)"; return 1; fi
    grep -Eq 'kind"?[[:space:]]*:' <<<"$stdin_yaml" || { _kn_refuse "apply: no kind in the manifest"; return 1; }
    while IFS= read -r kk; do
      [ -n "$kk" ] || continue
      _kn_in "$kk" "$applykinds" || { _kn_refuse "apply: manifest kind [$kk] is not one of [$applykinds]"; return 1; }
    done < <(grep -oE 'kind"?[[:space:]]*:[[:space:]]*"?[A-Za-z0-9]+' <<<"$stdin_yaml" | sed -E 's/.*:[[:space:]]*"?//')
    printf '%s\n' "$stdin_yaml" | kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
    return
  fi
  kubectl -n "$ns" "$verb" ${rest[@]+"${rest[@]}"}
}
