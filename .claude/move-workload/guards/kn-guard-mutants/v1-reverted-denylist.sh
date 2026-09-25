#!/bin/bash
# kn-guard.sh — a REUSABLE namespace-pinned kubectl wrapper with a verb + kind allow-list. Pure function definitions: no cluster call happens at source time.
# Written for bash 3.2 (/bin/bash on macOS). Used by pinfix-guards.sh; meant to be sourced by the sibling move-workload guards too.
#
# WHY: pinning `-n <ns>` is NOT a namespace boundary. kubectl takes the LAST -n/--namespace, and cluster-scoped kinds ignore -n entirely, so
#   kn <ns> --namespace ai delete pvc hermes | kn <ns> -n longhorn-system delete volumes.longhorn.io <pv> | kn <ns> delete pv <pv> | kn <ns> patch pv <pv> …
# all reach the API server through a naive `kubectl -n "$ns" "$@"`. This wrapper refuses all of them.
#
# USAGE (the sourcing guards set these BEFORE sourcing; they are read at call time; empty KN_NAMESPACES ⇒ every call is refused, fail closed):
#   KN_NAMESPACES="rehearsal-old rehearsal-new"   # the ONLY namespaces kn may address
#   KN_KINDS="..."                                # optional: replace the default kind allow-list (space separated, lower case)
#   KN_VERBS="..."                                # optional: replace the default verb allow-list
#   KN_APPLY_KINDS="Job"                          # optional: the manifest kinds `kn <ns> apply -f -` may carry (default: Job)
#   kn <ns> <verb> <kind|kind/name …> [flags]
#
# WHAT IS REFUSED:
#   * a namespace outside KN_NAMESPACES, or none;
#   * ANY later argument equal to / starting with -n, --namespace, -A, --all-namespaces (also -n=… and -nfoo forms);
#   * -s/--server, --context, --cluster, --user, --kubeconfig, --as*, --token*, --raw, --insecure*, and -f/--filename/-k/--kustomize/-R (except `apply -f -`);
#   * a verb outside the allow-list (get describe logs wait scale patch delete apply annotate label);
#   * a resource kind outside the allow-list — so pv, persistentvolume*, ns, namespace*, node*, crd*, clusterrole*, *.longhorn.io, storageclass*,
#     volumesnapshotcontent*, secret, … are all refused. Every kind in the FIRST positional (comma-split) and every `kind/name` positional is checked;
#     `key=value` positionals (annotate/label assignments) are not kinds and are skipped;
#   * `apply -f -` whose stdin carries a kind outside KN_APPLY_KINDS or any `namespace:` line.

KN_DEFAULT_VERBS="get describe logs wait scale patch delete apply annotate label"
KN_DEFAULT_KINDS="pod pods po deploy deployment deployments job jobs pvc pvcs persistentvolumeclaim persistentvolumeclaims ks kustomization kustomizations
 hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets volumesnapshot volumesnapshots event events
 replicationsource.volsync.backube replicationdestination.volsync.backube"

# _kn_in <word> <space-separated-list>
_kn_in() { local w=$1 x; for x in $2; do [ "$x" = "$w" ] && return 0; done; return 1; }

kn() {
  local ns=${1:-} verb a want_val=0 first=1 kinds verbs applykinds tok k stdin_yaml kk apply_stdin=0 prev=""
  [ $# -ge 2 ] || { echo "usage: kn <ns> <verb> <kind> …" >&2; return 1; }
  shift
  _kn_in "$ns" "${KN_NAMESPACES:-}" || { echo "REFUSE ns=[$ns] (allowed: [${KN_NAMESPACES:-}])" >&2; return 1; }
  verbs=${KN_VERBS:-$KN_DEFAULT_VERBS}; kinds=${KN_KINDS:-$KN_DEFAULT_KINDS}; applykinds=${KN_APPLY_KINDS:-Job}
  verb=${1:-}
  _kn_in "$verb" "$verbs" || { echo "REFUSE: kn verb [$verb] is not on the allow-list ($verbs)" >&2; return 1; }
  shift
  # pass 1: flags. Refuse every namespace/context/file/cluster override, anywhere.
  for a in "$@"; do
    case "$a" in
      -n|-n*|--namespace|--namespace=*|-A|-A*|--all-namespaces|--all-namespaces=*) echo "REFUSE: kn does not accept [$a] (the namespace is fixed to [$ns])" >&2; return 1;;
      -s|-s=*|--server|--server=*|--context|--context=*|--cluster|--cluster=*|--user|--user=*|--kubeconfig|--kubeconfig=*|--as|--as=*|--as-group|--as-group=*|--as-uid|--as-uid=*|--token|--token=*|--raw|--raw=*|--insecure-skip-tls-verify|--insecure-skip-tls-verify=*)
        echo "REFUSE: kn does not accept [$a]" >&2; return 1;;
      -k|-k*|--kustomize|--kustomize=*|-R|--recursive|--recursive=*) echo "REFUSE: kn does not accept [$a]" >&2; return 1;;
    esac
  done
  # pass 2: positionals. Skip the value of flags that take a separate value.
  for a in "$@"; do
    if [ "$want_val" = 1 ]; then
      want_val=0
      if [ "$prev" = "-f" ] || [ "$prev" = "--filename" ]; then
        [ "$verb" = apply ] && [ "$a" = "-" ] || { echo "REFUSE: kn accepts a file only as 'apply -f -' (got $prev $a)" >&2; return 1; }
        apply_stdin=1
      fi
      continue
    fi
    case "$a" in
      -f|--filename)
        [ "$verb" = apply ] || { echo "REFUSE: kn accepts -f only for apply" >&2; return 1; }
        want_val=1; prev=$a; continue;;
      -f=*|--filename=*) echo "REFUSE: kn accepts a file only as 'apply -f -'" >&2; return 1;;
      -o|--output|-l|--selector|-p|--patch|--type|--timeout|--field-selector|--sort-by|-c|--container|--tail|--since|--limit-bytes|--dry-run|--for|--replicas|--cascade|--grace-period|--overwrite-x)
        want_val=1; prev=$a; continue;;
      -*) continue;;
    esac
    case "$a" in *=*) continue;; esac                      # key=value (annotate/label assignment): not a kind
    if [ "$first" = 1 ]; then
      first=0
      # the first positional is the resource type list (kind[,kind…]) or kind/name; apply/logs/scale forms are covered by the same rule
      tok=${a%%/*}
      for k in $(printf '%s' "$tok" | tr ',' ' '); do
        _kn_in "$k" "$kinds" || { echo "REFUSE: kn kind [$k] is not on the allow-list" >&2; return 1; }
      done
    fi
    case "$a" in */*) k=${a%%/*}; _kn_in "$k" "$kinds" || { echo "REFUSE: kn kind [$k] (in [$a]) is not on the allow-list" >&2; return 1; };; esac
  done
  [ "$want_val" = 0 ] || { echo "REFUSE: kn: flag [$prev] has no value" >&2; return 1; }
  if [ "$verb" = apply ]; then
    [ "$apply_stdin" = 1 ] || { echo "REFUSE: kn apply needs -f -" >&2; return 1; }
    stdin_yaml=$(cat)
    if grep -Eiq 'namespace["'\'']?[[:space:]]*:' <<<"$stdin_yaml"; then echo "REFUSE: kn apply: manifest names a namespace" >&2; return 1; fi
    while IFS= read -r kk; do
      [ -n "$kk" ] || continue
      _kn_in "$kk" "$applykinds" || { echo "REFUSE: kn apply: manifest kind [$kk] is not one of [$applykinds]" >&2; return 1; }
    done < <(sed -nE 's/^kind:[[:space:]]*([A-Za-z]+).*/\1/p' <<<"$stdin_yaml")
    grep -Eq '^kind:' <<<"$stdin_yaml" || { echo "REFUSE: kn apply: no kind in the manifest" >&2; return 1; }
    printf '%s\n' "$stdin_yaml" | kubectl -n "$ns" "$verb" "$@"
    return
  fi
  kubectl -n "$ns" "$verb" "$@"
}
