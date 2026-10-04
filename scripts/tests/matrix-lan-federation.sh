#!/bin/bash
# LAN federation via hostAliases (NOT ip_range_whitelist).
# flux-local build hr does NOT run postRenderers, so: real chart render as base + the HelmRelease's
# own postRenderers[0].kustomize.patches (envsubst'd with test values) applied by kustomize --
# exactly what helm-controller does.
#  1. both synapse-main StatefulSets carry hostAliases ip=<SECRET_PANGOLIN_IP> for both matrix.* hosts
#  2. no Synapse config sets ip_range_whitelist (the rejected #2059 approach); the chart's own
#     url_preview_ip_range_whitelist is a different key and is ignored
#  3. existing patches still apply (Ingresses deleted, synapse reload annotation kept)
#  4. CoreDNS answers the bluevulpine.net zone from public DNS (apex .well-known fetchable),
#     AAAA still suppressed there, main block untouched, values bootstrap-safe (no ${...})
#  5. the rejected _matrix-fed SRV approach is gone
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
export SECRET_DOMAIN=derekjacobs.dev SECRET_DOMAIN_BLOG=bluevulpine.net SECRET_PANGOLIN_IP=203.0.113.10
fail=0
# flux-local occasionally returns an empty render when invoked back-to-back; retry before failing.
fl() { local o i; for i in 1 2 3; do o=$(flux-local build hr "$@" --path kubernetes/flux/cluster 2>/dev/null); [ -n "$o" ] && { printf '%s\n' "$o"; return 0; }; sleep 2; done; return 1; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for ns in matrix matrix-bluevulpine; do
  d="$tmp/$ns"; mkdir -p "$d"
  fl matrix-stack -n "$ns" --no-skip-secrets > "$d/base.yaml"
  [ -s "$d/base.yaml" ] || { echo "FAIL $ns: empty render"; fail=1; continue; }
  yq '{"resources":["base.yaml"],"patches":.spec.postRenderers[0].kustomize.patches}' \
    "kubernetes/apps/$ns/matrix-stack/app/helmrelease.yaml" | flux envsubst > "$d/kustomization.yaml"
  out=$(kustomize build "$d" 2>&1) || { echo "FAIL $ns kustomize: $(echo "$out" | head -2)"; fail=1; continue; }
  sts='select(.kind=="StatefulSet" and .metadata.name=="matrix-stack-synapse-main")'
  ha=$(printf '%s\n' "$out" | yq -o=json "$sts | .spec.template.spec.hostAliases" | jq -c '[.[]? | {ip, hostnames: (.hostnames|sort)}]')
  check "$ns hostAliases" "$ha" '[{"ip":"203.0.113.10","hostnames":["matrix.bluevulpine.net","matrix.derekjacobs.dev"]}]'
  # ndots:1 so dotted names are tried ABSOLUTE first: with the default ndots:5 the search walk is
  # done server-side by CoreDNS autopath inside the "." block, which forwards to UniFi and returns
  # the internal 172.16.8.2 for bluevulpine.net -- never reaching the bluevulpine.net. zone block.
  check "$ns dnsConfig ndots:1" "$(printf '%s\n' "$out" | yq -o=json "$sts | .spec.template.spec.dnsConfig.options" | jq -c '[.[]? | select(.name=="ndots") | .value]')" '["1"]'
  check "$ns no-ip_range_whitelist" "$(printf '%s\n' "$out" | grep -c -E '^[[:space:]]*ip_range_whitelist:')" "0"
  check "$ns reload-annotation-kept" "$(printf '%s\n' "$out" | yq "$sts | .metadata.annotations[\"secret.reloader.stakater.com/reload\"]")" "matrix-stack-secret"
  check "$ns ingresses-deleted" "$(printf '%s\n' "$out" | yq 'select(.kind=="Ingress") | .metadata.name' | grep -c -v -E '^(---)?$')" "0"
done
# CoreDNS: the bluevulpine.net zone is answered from public DNS (its apex .well-known must be
# fetchable by the derekjacobs.dev Synapse), with AAAA still suppressed in that block.
cf=$(fl coredns -n kube-system | yq 'select(.kind=="ConfigMap" and .metadata.name=="coredns") | .data.Corefile')
blk=$(printf '%s\n' "$cf" | awk '/^dns:\/\/bluevulpine\.net\.:53 /{f=1} f{print} f&&/^}/{exit}')
check "coredns bluevulpine block present" "$([ -n "$blk" ] && echo yes)" "yes"
check "coredns block forwards public" "$(printf '%s\n' "$blk" | grep -c -E '^\s*forward \. 1\.1\.1\.1 1\.0\.0\.1')" "1"
check "coredns block suppresses AAAA" "$(printf '%s\n' "$blk" | grep -c -E '^\s*template ANY AAAA')" "1"
check "coredns block has metrics" "$(printf '%s\n' "$blk" | grep -c -E '^\s*prometheus 0\.0\.0\.0:9153')" "1"
check "coredns block SOA absolute" "$(printf '%s\n' "$blk" | grep -c 'ns.dns. hostmaster.dns.')" "1"
check "coredns main block unchanged forward" "$(printf '%s\n' "$cf" | grep -c -E '^\s*forward \. /etc/resolv\.conf')" "1"
# Bootstrap safety: bootstrap/helmfile.d reads these values raw, so no Flux placeholder may appear
# in any VALUE (JSON output: comments, which fromYaml drops anyway, are not counted).
check "coredns values bootstrap-safe (no \${})" "$(yq -o=json '.spec.values' kubernetes/apps/kube-system/coredns/app/helmrelease.yaml | grep -c '\${')" "0"
# The rejected SRV approach must not linger.
check "no _matrix-fed SRV endpoint" "$(grep -rc '_matrix-fed' kubernetes/apps/matrix-bluevulpine/ | awk -F: '{s+=$2} END{print s+0}')" "0"
exit $fail
