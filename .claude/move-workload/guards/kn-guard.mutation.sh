#!/bin/bash
# kn-guard.mutation.sh — proves kn-guard.test.sh actually CATCHES weakened guards. Mutants: the two shipped-and-broken earlier versions (kn-guard-mutants/) and single-edit
# weakenings of the CURRENT kn-guard.sh (one per rule; includes the independent reviewer's X1-X4 and X11 in their current form). Each mutant must make the suite report
# at least one FAIL, and the named tests must be among the failures. Under /bin/bash; no cluster; the mutants live in a temp dir. Exit 1 if any mutant survives.
# shellcheck disable=SC2016
# ^ SC2016: the mutation patterns are literal shell source.
[ -n "${BASH_VERSION:-}" ] || { echo "run under /bin/bash (never zsh)" >&2; exit 99; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/kn-mut.XXXXXX"); trap 'rm -rf "$W"' EXIT
bad=0; total=0
# run_mutant <name> <file> <must-fail test-name substring>…
run_mutant() {
  local name=$1 f=$2 out n miss="" want; shift 2
  total=$((total + 1))
  if [ "${KN_MUT_DRY:-}" = 1 ]; then echo "DRY      $name"; return; fi          # KN_MUT_DRY=1: only check that every mutation pattern still exists in kn-guard.sh
  out=$(/bin/bash "$HERE/kn-guard.test.sh" "$f" 2>&1); n=$(grep -c '^FAIL' <<<"$out" || true)
  for want in "$@"; do grep '^FAIL' <<<"$out" | grep -qF -- "$want" || miss="$miss [$want]"; done
  if [ "$n" -ge 1 ] && [ -z "$miss" ]; then echo "KILLED   $name  ($n tests fail)"; else echo "SURVIVED $name  (fails=$n; expected-to-fail but passing:$miss)"; bad=$((bad+1)); fi
}
# mutate <name> <old> <new> [all]: $W/<name>.sh = kn-guard.sh with the FIRST (or ALL) occurrence(s) of <old> replaced. Aborts the harness if <old> is absent.
mutate() {
  python3 - "$HERE/kn-guard.sh" "$W/$1.sh" "$2" "$3" "${4:-}" <<'PY' || { echo "MUTATION PATTERN NOT FOUND: $1" >&2; exit 98; }
import sys
src, dst, old, new, allf = sys.argv[1:6]
s = open(src).read()
if old not in s: sys.exit(1)
open(dst, 'w').write(s.replace(old, new) if allf == 'all' else s.replace(old, new, 1))
PY
}
if [ "${KN_MUT_DRY:-}" != 1 ]; then echo "current guard passes its own suite:"; /bin/bash "$HERE/kn-guard.test.sh" "$HERE/kn-guard.sh" | tail -1; fi
echo "== earlier versions =="
run_mutant "v1 (exact-token deny-list; broken by the 2nd review)" "$HERE/kn-guard-mutants/v1-reverted-denylist.sh" "N2: get pods -RA" "N2: logs pod/x -pnkube-system" "N2: get pods -shttps"
run_mutant "v2 (49ae28f7: grep kind check, no per-verb arity; broken by the 3rd review)" "$HERE/kn-guard-mutants/v2-reverted-49ae28f7.sh" "F1: logs pod/x -p -nkube-system" "F3: delete pvc/a clusterrole/x=y" "F5: KN_EXTRA_BOOL_FLAGS=--namespace" "F6: delete pvc -l" "F7: env seen by kubectl"
run_mutant "v3 (6256dd68: yq/YAML parse, root-kind check only; broken by the 4th review)" "$HERE/kn-guard-mutants/v3-reverted-6256dd68.sh" "R3-1: Job + items[Namespace] (JSON)" "R3-1: Job + items[ClusterRoleBinding]" "R3-4: underscore spelling" "R3-5: KN_HARD_DENY_VERBS=''" "R3-6a: get '' secrets"
run_mutant "v4 (2f001021: lenient jq parse, additive-less controller knob, joined apiVersion/kind; broken by the 5th review)" "$HERE/kn-guard-mutants/v4-reverted-2f001021.sh" "R4-1: number literal 0400 refused" "R4-2: KN_CONTROLLER_KINDS='' does not lift the ks write ban" "R4-3: --log-file=/tmp/x refused" "R4-4: apiVersion 'batch' + kind 'v1/Job'"
echo "== flags =="
mutate M1 '      -*) _kn_refuse "flag [$a] is not on the allow-list (single-dash' '      -*) : ;;
      -zzz) _kn_refuse "flag [$a] is not on the allow-list (single-dash'
run_mutant "M1 single-dash / combined short flags accepted"        "$W/M1.sh" "N2: get pods -RA" "N2: delete pvc hermes -Rnkube-system" "N2: get pods -shttps" "N2: get pods -A=true"
mutate M2 '          _kn_refuse "flag [$a] is not on the allow-list"; return 1' '          :'
run_mutant "M2 unknown long flags accepted"                        "$W/M2.sh" "unknown long flag refused"
mutate M3 '[ "$hasval" = 1 ] || { _kn_refuse "flag [$a] must be written $a=<value>"; return 1; }' ':'
run_mutant "M3 space-separated --timeout/--replicas accepted"      "$W/M3.sh" "--timeout with a space" "--replicas with a space"
mutate M7 "--) _kn_refuse \"'--' is not accepted\"; return 1;;" '--) ;;'
run_mutant "M7 bare -- accepted"                                   "$W/M7.sh" "get pods --"
mutate M11 'LONG_BOOL) echo "--wait' 'LONG_BOOL) echo "--all --wait'
run_mutant "M11 --all on the default allow-list"                   "$W/M11.sh" "--all not on the default allow-list"
mutate X1 '          if [ "$hasval" = 1 ]; then
            case "$name" in --selector' '          if [ "$hasval" = 9 ]; then
            case "$name" in --selector'
run_mutant "X1 --flag=value also consumes the next token"          "$W/X1.sh" "X1: --output=json does NOT consume" "X1: --selector=x=y does not consume"
mutate F1a '-p) case "$1" in patch) echo val;; logs) echo bool;;' '-p) case "$1" in patch|logs) echo val;;'
run_mutant "F1a logs -p treated as value-taking"                   "$W/F1a.sh" "F1: logs pod/x -p -nkube-system" "F1: logs -p -nkube-system pod/x" "F1: logs pod/x -p --namespace=kube-system" "F1: logs -p secrets/x"
mutate F1b '          *) _kn_refuse "short flag [$a] is not allowed for '"'"'$verb'"'"'"; return 1;;' '          *) ;;'
run_mutant "F1b short flags unknown to a verb accepted"            "$W/F1b.sh" "F1: get -p refused" "F1: delete -c refused" "F1: describe -o refused"
mutate F1c '  _kn_in "$1" "$(_kn_L DEFAULT_VERBS)" || { echo deny; return; }' ':'
run_mutant "F1c verbs added via KN_VERBS get short flags"          "$W/F1c.sh" "F1: a verb added through KN_VERBS gets NO short flags"
mutate R34a 'name=${a%%=*}; name=${name//_/-}; hasval=0' 'name=${a%%=*}; hasval=0'
run_mutant "R3-4a underscore spellings are not normalised"         "$W/R34a.sh" "R3-4: underscore spelling --all_namespaces" "R3-4: underscore spelling --as_group=x" "R3-4: underscore spelling --client_key=/x"
mutate R34b '        elif _kn_in "$name" "$(_kn_L LONG_BOOL)"; then continue' '        elif _kn_in "$name" "$(_kn_L LONG_BOOL) ${KN_EXTRA_BOOL_FLAGS:-}"; then continue'
run_mutant "R3-4b extra flags consulted with the built-in booleans (bare form allowed)" "$W/R34b.sh" "R3-4: an extra flag in the bare form is refused" "R3-4: KN_EXTRA_BOOL_FLAGS=--template cannot swallow a kind"
mutate R34c '          [ "$hasval" = 1 ] || { _kn_refuse "extra flag [$a] must be written $a=<value> (kn cannot know whether an unlisted flag consumes the next token)"; return 1; }' '          :'
run_mutant "R3-4c extra flags accepted without =value"             "$W/R34c.sh" "R3-4: an extra flag in the bare form is refused" "R3-4: KN_EXTRA_BOOL_FLAGS=--template cannot swallow a kind"
mutate R34d ' --proxy-url --cache-dir --kuberc --log-file' ' --log-file'
run_mutant "R3-4d --proxy-url/--cache-dir/--kuberc missing from the deny list" "$W/R34d.sh" "R3-4: --proxy-url=http://evil:3128 refused by name" "R3-4: --cache-dir=/tmp/x refused by name" "R3-4: --kuberc=/tmp/evil refused by name"
mutate R34e ' --as-user-extra --token' ' --token'
run_mutant "R3-4e --as-user-extra missing from the deny list"      "$W/R34e.sh" "R3-4: --as-user-extra=a=b refused by name"
echo "== environment, verbs, kinds =="
mutate M4 '[ -z "${KUBERNETES_MASTER:-}" ] || { _kn_refuse "KUBERNETES_MASTER is set (it redirects kubectl to another API server)"; return 1; }' ':'
run_mutant "M4 KUBERNETES_MASTER not checked"                      "$W/M4.sh" "KUBERNETES_MASTER set refused"
mutate M10 'if [ -n "${KN_KUBECONFIG_PIN:-}" ]' 'if false && [ -n "${KN_KUBECONFIG_PIN:-}" ]'
run_mutant "M10 KN_KUBECONFIG_PIN ignored"                         "$W/M10.sh" "KN_KUBECONFIG_PIN mismatch"
mutate M12 '  _kn_in "$ns" "${KN_NAMESPACES:-}" ||' '  true ||'
run_mutant "M12 namespace list not enforced"                       "$W/M12.sh" "ns outside the list refused"
mutate M5 '    HARD_DENY_VERBS) echo "exec cp port-forward debug proxy attach auth run create edit replace config plugin";;' '    HARD_DENY_VERBS) echo "";;'
run_mutant "M5 hard-deny verbs removed"                            "$W/M5.sh" "exec stays refused even if KN_VERBS" "port-forward stays refused"
mutate R35 '    HARD_DENY_VERBS) echo "exec cp port-forward debug proxy attach auth run create edit replace config plugin";;' '    HARD_DENY_VERBS) echo "${KN_HARD_DENY_VERBS-exec cp port-forward debug proxy attach auth run create edit replace config plugin}";;'
run_mutant "R3-5 the hard-deny list is an overridable KN_ variable" "$W/R35.sh" "R3-5: KN_HARD_DENY_VERBS='' cannot re-enable exec"
mutate R35b '    LONG_DENY) echo "--namespace' '    LONG_DENY) echo "${KN_LONG_DENY---namespace}'
run_mutant "R3-5b the named-deny flag list is an overridable variable" "$W/R35b.sh" "R3-5: KN_LONG_DENY='' + extra flag cannot re-enable --namespace"
mutate R35c '    SELECTOR_RE) echo '"'"'^[A-Za-z0-9_./-]+' '    SELECTOR_RE) echo "${KN_SELECTOR_RE-^[A-Za-z0-9_./-]+}"; return; echo '"'"'^[A-Za-z0-9_./-]+'
run_mutant "R3-5c the selector regex is an overridable variable"   "$W/R35c.sh" "R3-5: KN_SELECTOR_RE='.*' cannot lift the selector rule"
mutate M6 '    DEFAULT_KINDS) echo "pod pods' '    DEFAULT_KINDS) echo "secret secrets pod pods'
run_mutant "M6 secrets added to the kind allow-list"               "$W/M6.sh" "get secrets" "get secret -o yaml" "describe secrets"
mutate F3a "              *=*) _kn_refuse \"positional [\$a] contains '=' (only annotate/label key=value pairs after a resource are accepted)\"; return 1;;" '              *=*) continue;;'
run_mutant "F3a positionals containing '=' skip the kind check"    "$W/F3a.sh" "F3: delete pvc/a clusterrole/x=y" "F3: get secret/a=b" "F3: get secrets,pods=x"
mutate X11 'if { [ "$verb" = annotate ] || [ "$verb" = label ]; } && [ "$first" = 0 ]; then pairs=1; continue; fi' 'if [ "$first" = 0 ]; then pairs=1; continue; fi'
run_mutant "X11 key=value / key- pairs honoured for every verb"     "$W/X11.sh" "X11: delete pvc/a secret/b-" "X11: get pvc/a secret/b-" "F3: delete pvc/a clusterrole/x=y"
mutate R36a "      ''|=*) _kn_refuse \"positional [\$a] is empty or starts with '='\"; return 1;;" '      "") : ;;'
run_mutant "R3-6a empty / '='-leading positionals accepted"        "$W/R36a.sh" "R3-6a: get '' secrets" "R3-6b: annotate pvc/a =b/c secret/y a=b" "R3-6b: delete pvc =x"
mutate F5 'if _kn_in "$name" "$(_kn_L LONG_DENY)" || case "$name" in --client-*) true;; *) false;; esac; then' 'if false; then'
run_mutant "F5 named-deny list not checked before the allow-lists" "$W/F5.sh" "F5: KN_EXTRA_BOOL_FLAGS=--namespace" "F5: KN_EXTRA_BOOL_FLAGS=--all-namespaces" "F5: KN_EXTRA_BOOL_FLAGS=--server"
mutate F6a '  [[ "$2" =~ $re ]] && return 0' '  return 0'
run_mutant "F6a selectors unrestricted on write verbs"             "$W/F6a.sh" "F6: delete pvc -l 'x!=y'" "F6: delete pvc --field-selector"
mutate F6b '    SELECTOR_VERBS) echo "delete patch' '    SELECTOR_VERBS) echo "patch'
run_mutant "F6b delete dropped from the selector-checked verbs"    "$W/F6b.sh" "F6: delete pvc -l 'x!=y'"
mutate Y2 '    SELECTOR_VERBS) echo "delete patch apply annotate label scale";;' '    SELECTOR_VERBS) echo "delete patch apply annotate scale";;'
run_mutant "Y2 label dropped from the selector-checked verbs"      "$W/Y2.sh" "Y2: label pvc -l 'x!=y' a=b"
mutate Y3 '    SELECTOR_VERBS) echo "delete patch apply annotate label scale";;' '    SELECTOR_VERBS) echo "delete patch annotate label scale";;'
run_mutant "Y3 apply dropped from the selector-checked verbs"      "$W/Y3.sh" "Y3: apply -f - -l 'x!=y'"
mutate F6c '            [ "$a" = -l ] && { _kn_selector_ok "$verb" "${rest[$i]}" || return 1; }' '            :'
run_mutant "F6c the -l short-flag value is not checked"            "$W/F6c.sh" "F6: delete pvc -l 'x!=y'" "F6: patch pvc -l"
mutate F7a 'env KUBERC=off KUBECTL_KUBERC=false kubectl' 'kubectl' all
run_mutant "F7a kubectl run without disabling the kuberc"          "$W/F7a.sh" "F7: env seen by kubectl" "F7 apply env"
mutate F7b '    printf '"'"'%s\n'"'"' "$canon" | env KUBERC=off KUBECTL_KUBERC=false kubectl' '    printf '"'"'%s\n'"'"' "$canon" | kubectl'
run_mutant "F7b the apply path runs kubectl without KUBERC=off"    "$W/F7b.sh" "F7 apply env"
mutate D1a '    CONTROLLER_KINDS) echo "ks ' '    CONTROLLER_KINDS) echo "zz '
run_mutant "D1a controller kinds may be patched"                   "$W/D1a.sh" "D1: patch ks refused" "D1: annotate ks refused"
mutate Y14 '    CONTROLLER_KINDS) echo "ks kustomization kustomizations hr helmrelease helmreleases ocirepository ocirepositories externalsecret externalsecrets' '    CONTROLLER_KINDS) echo "ks kustomization hr helmrelease ocirepository externalsecret'
run_mutant "Y14 plural controller kinds (and qualified names) patchable" "$W/Y14.sh" "D1: patch kustomizations refused" "D1: patch helmreleases refused" "D1: patch ocirepositories refused" "D1: patch externalsecrets refused"
mutate Y14b ' kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io externalsecrets.external-secrets.io";;' '";;'
run_mutant "Y14b qualified controller kinds missing from the controller list" "$W/Y14b.sh" "D1: qualified kustomizations.kustomize.toolkit.fluxcd.io added via KN_KINDS is still read/delete only" "D1: qualified externalsecrets.external-secrets.io added via KN_KINDS is still read/delete only"
mutate D1b '    MUTATE_VERBS) echo "patch apply annotate label scale";;' '    MUTATE_VERBS) echo "apply";;'
run_mutant "D1b write verbs dropped from the controller-kind rule" "$W/D1b.sh" "D1: patch ks refused" "D1: scale ks refused"
echo "== the IFS / noglob lines of kn() =="
mutate Y1 '  set -f
  _kn_main' '  :
  _kn_main'
run_mutant "Y1 kn() no longer sets noglob"                         "$W/Y1.sh" "Y1: a glob in KN_NAMESPACES is NOT expanded" "Y1: a glob in KN_KINDS is NOT expanded"
mutate Y7 "  local _kn_opts=\$- _kn_rc IFS=\$' \\t\\n'" '  local _kn_opts=$- _kn_rc'
run_mutant "Y7 kn() no longer resets IFS"                          "$W/Y7.sh" "Y1/IFS: strict-mode IFS does not break the namespace list" "Y1/IFS: IFS=x cannot split"
mutate Y8 '  case $_kn_opts in *f*) ;; *) set +f;; esac' '  :'
run_mutant "Y8 kn() does not restore the caller's noglob state"    "$W/Y8.sh" "F4: the caller's noglob state is restored (set +f stays +f)"
echo "== apply / manifest parse =="
mutate R31 '          and (([keys[] | ascii_downcase] | index("items")) == null)' '          and true'
run_mutant "R3-1 top-level items key not refused"                  "$W/R31.sh" "R3-1: Job + items[Namespace] (JSON)" "R3-1: Job + items[ClusterRoleBinding]" "R3-1: Job + items[PV hostPath /]" "R3-1: kind List even when KN_APPLY_KINDS lists it" "R3-1: an Items / ITEMS key"
mutate R31b '          and (([keys[] | ascii_downcase] | length) == ([keys[] | ascii_downcase] | unique | length))' '          and true'
run_mutant "R3-1b case-colliding root keys (kind/KIND) accepted"   "$W/R31b.sh" "case-variant root keys KIND / Kind refused" "case-variant apiversion refused"
mutate P1 '      and all(.[];' '      and any(.[];'
run_mutant "P1 only ONE document has to pass (all -> any)"         "$W/P1.sh" "apply -f - Job then a PV document refused" "apply -f - a PV document hidden LAST among many refused" "apply -f - a PV document FIRST then Jobs refused"
mutate P2 '    canon=$(_kn_apply_canon "$applykinds") || return 1' '    canon=$(cat)'
run_mutant "P2 the ORIGINAL bytes (unchecked) go to kubectl"       "$W/P2.sh" "stdin of kubectl == the canonical JSON that was checked" "apply -f - PersistentVolume refused" "R3-1: Job + items[Namespace] (JSON)"
mutate P3 '  if ! command -v jq >/dev/null 2>&1; then _kn_refuse "apply needs jq to parse the manifest; refusing"; return 1; fi' ':'
run_mutant "P3 a missing parser is not refused"                    "$W/P3.sh" "apply refused when jq is missing"
mutate P4 '          and (([.. | objects | keys[] | ascii_downcase | select(. == "namespace")] | length) == 0))' '          and true)'
run_mutant "P4 namespace keys are not looked for"                  "$W/P4.sh" "apply -f - Job naming a namespace refused" "apply -f - Job with a namespace key deep in the spec refused" "apply -f - Job with a Namespace-cased key refused"
mutate P4b '          and (([.. | objects | keys[] | ascii_downcase | select(. == "namespace")] | length) == 0))' '          and (([.. | objects | keys[] | select(. == "namespace")] | length) == 0))'
run_mutant "P4b namespace looked for case-sensitively only"        "$W/P4b.sh" "apply -f - Job with a Namespace-cased key refused"
mutate P5 '          and (. as $d | any($ok[]; .av == $d.apiVersion and .k == $d.kind))' '          and (. as $d | any($ok[]; .k == $d.kind))'
run_mutant "P5 apiVersion is not pinned with the kind"             "$W/P5.sh" "apiVersion example.com/v1 + kind Job" "apiVersion batch/v1beta1 + kind Job refused"
mutate P6 'in ?*/?*) ;; *) _kn_refuse "KN_APPLY_KINDS entry' 'in *) ;; zzz) _kn_refuse "KN_APPLY_KINDS entry'
run_mutant "P6 malformed KN_APPLY_KINDS entries are accepted"      "$W/P6.sh" "KN_APPLY_KINDS entry without a group/version fails closed"
# P7 (dropping the second "no document" check) is an EQUIVALENT mutant and is deliberately not listed: the strict validator's exit status 3 already refuses an empty manifest
# with the same message, so the later `[ -n "$canon" ]` check is defence in depth.
mutate P8 '        [ "$i" -lt "$n" ] && [ "${rest[$i]}" = "-" ] || { _kn_refuse "-f accepts only '"'"'-'"'"' (stdin)"; return 1; }' '        :'
run_mutant "P8 apply -f <file> accepted"                           "$W/P8.sh" "apply -f file refused"
mutate X2 '    [ "$apply_stdin" = 1 ] || { _kn_refuse "apply needs -f -"; return 1; }' ':'
run_mutant "X2 apply without -f - accepted"                        "$W/X2.sh" "apply without -f - refused"
mutate P6b 'in ?*/?*) ;; *) _kn_refuse "KN_APPLY_KINDS entry' 'in */?*) ;; *) _kn_refuse "KN_APPLY_KINDS entry'
run_mutant "P6b an empty apiVersion in KN_APPLY_KINDS ('/Job') is accepted" "$W/P6b.sh" "R4-4: a KN_APPLY_KINDS entry '/Job'"
mutate R41a 'case "$rc" in 0) ;;' 'rc=0; case "$rc" in 0) ;;'
run_mutant "R4-1a the strict-JSON validator result is ignored (jq's lenient parse decides)" "$W/R41a.sh" "R4-1: number literal 0400 refused" "R4-1: number literal +1 refused" "R4-1: number literal .5 refused" "R4-1: number literal nan refused" "R4-1: number literal infinity refused" "R4-1: defaultMode 0400 in a Secret volume"
mutate R41b 'parse_constant=bad, ' ''
run_mutant "R4-1b NaN/Infinity constants accepted by the validator" "$W/R41b.sh" "R4-1: number literal NaN refused" "R4-1: number literal Infinity refused" "R4-1: number literal -Infinity refused"
mutate R41c '    if math.isinf(v) or math.isnan(v): raise ValueError("float out of range")' '    pass'
run_mutant "R4-1c float overflow (1e999) accepted"                 "$W/R41c.sh" "R4-1: number literal 1e999 refused" "R4-1: number literal -1e999 refused"
mutate R41d '  if ! command -v python3 >/dev/null 2>&1; then _kn_refuse "apply needs python3 to validate the manifest as STRICT JSON (jq'"'"'s parser is lenient); refusing"; return 1; fi' ':'
run_mutant "R4-1d a missing python3 is not reported as such"       "$W/R41d.sh" "apply refused when python3 is missing"
mutate R41e 'strict=True' 'strict=False'
run_mutant "R4-1e control characters inside strings accepted"      "$W/R41e.sh" "R4-1: a raw newline inside a string is refused"
mutate R42 'ctl="$(_kn_L CONTROLLER_KINDS) ${KN_CONTROLLER_KINDS:-}"' 'ctl=${KN_CONTROLLER_KINDS-$(_kn_L CONTROLLER_KINDS)}'
run_mutant "R4-2 the controller knob REPLACES the built-in list (empty lifts D1)" "$W/R42.sh" "R4-2: KN_CONTROLLER_KINDS='' does not lift the ks write ban" "R4-2: KN_CONTROLLER_KINDS=zz does not lift it either" "R4-2: annotate ks with the knob empty"
mutate R42b 'ctl="$(_kn_L CONTROLLER_KINDS) ${KN_CONTROLLER_KINDS:-}"' 'ctl="$(_kn_L CONTROLLER_KINDS)"'
run_mutant "R4-2b the controller knob no longer ADDS kinds"        "$W/R42b.sh" "R4-2: the knob ADDS a kind (pvc becomes read/delete only)"
mutate R43 ' --log-file --log-dir --log-file-max-size --log-backtrace-at --log-flush-frequency --v --vmodule";;' '";;'
run_mutant "R4-3 the log flags are not on the named-deny list"     "$W/R43.sh" "R4-3: --log-file=/tmp/x refused" "R4-3: --v=9 refused" "R4-3: --log-dir=/tmp refused"
mutate R44 '          and (. as $d | any($ok[]; .av == $d.apiVersion and .k == $d.kind))' '          and (((.apiVersion + "/" + .kind)) as $av | ($ok | map(.av + "/" + .k) | index($av)) != null)'
run_mutant "R4-4 apiVersion and kind compared as one joined string" "$W/R44.sh" "R4-4: apiVersion 'batch' + kind 'v1/Job'"
mutate P10 '_kn_refuse "apply: every JSON document must be an object with' '_kn_refuse "apply: $canon every JSON document must be an object with'
run_mutant "P10 the refusal message echoes the manifest (Secret stringData)" "$W/P10.sh" "the refusal message leaked manifest content"
echo
echo "$total mutants run"
if [ "$bad" -eq 0 ]; then echo "ALL MUTANTS KILLED"; else echo "$bad MUTANT(S) SURVIVED"; exit 1; fi
