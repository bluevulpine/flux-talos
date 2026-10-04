#!/bin/bash
# LAN federation via hostAliases (NOT ip_range_whitelist).
# flux-local build hr does NOT run postRenderers, so: real chart render as base + the HelmRelease's
# own postRenderers[0].kustomize.patches (envsubst'd with test values) applied by kustomize --
# exactly what helm-controller does.
#  1. both synapse-main StatefulSets carry hostAliases ip=<SECRET_PANGOLIN_IP> for both matrix.* hosts
#  2. no Synapse config sets ip_range_whitelist (the rejected #2059 approach); the chart's own
#     url_preview_ip_range_whitelist is a different key and is ignored
#  3. existing patches still apply (Ingresses deleted, synapse reload annotation kept)
#  4. matrix-bluevulpine DNSEndpoint publishes _matrix-fed._tcp.<blog> SRV -> matrix.<blog>:443
#  5. external-dns (cloudflare) manages SRV
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
export SECRET_DOMAIN=derekjacobs.dev SECRET_DOMAIN_BLOG=bluevulpine.net SECRET_PANGOLIN_IP=203.0.113.10
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for ns in matrix matrix-bluevulpine; do
  d="$tmp/$ns"; mkdir -p "$d"
  flux-local build hr matrix-stack -n "$ns" --path kubernetes/flux/cluster --no-skip-secrets > "$d/base.yaml" 2>/dev/null
  [ -s "$d/base.yaml" ] || { echo "FAIL $ns: empty render"; fail=1; continue; }
  yq '{"resources":["base.yaml"],"patches":.spec.postRenderers[0].kustomize.patches}' \
    "kubernetes/apps/$ns/matrix-stack/app/helmrelease.yaml" | flux envsubst > "$d/kustomization.yaml"
  out=$(kustomize build "$d" 2>&1) || { echo "FAIL $ns kustomize: $(echo "$out" | head -2)"; fail=1; continue; }
  sts='select(.kind=="StatefulSet" and .metadata.name=="matrix-stack-synapse-main")'
  ha=$(printf '%s\n' "$out" | yq -o=json "$sts | .spec.template.spec.hostAliases" | jq -c '[.[]? | {ip, hostnames: (.hostnames|sort)}]')
  check "$ns hostAliases" "$ha" '[{"ip":"203.0.113.10","hostnames":["matrix.bluevulpine.net","matrix.derekjacobs.dev"]}]'
  check "$ns no-ip_range_whitelist" "$(printf '%s\n' "$out" | grep -c -E '^[[:space:]]*ip_range_whitelist:')" "0"
  check "$ns reload-annotation-kept" "$(printf '%s\n' "$out" | yq "$sts | .metadata.annotations[\"secret.reloader.stakater.com/reload\"]")" "matrix-stack-secret"
  check "$ns ingresses-deleted" "$(printf '%s\n' "$out" | yq 'select(.kind=="Ingress") | .metadata.name' | grep -c -v -E '^(---)?$')" "0"
done
ks=$(kustomize build kubernetes/apps/matrix-bluevulpine/matrix-stack/app)
srv=$(printf '%s\n' "$ks" | yq -o=json 'select(.kind=="DNSEndpoint") | .spec.endpoints[] | select(.recordType=="SRV")' | jq -c '{dnsName, targets}')
check "srv-endpoint" "$srv" '{"dnsName":"_matrix-fed._tcp.${SECRET_DOMAIN_BLOG}","targets":["10 0 443 matrix.${SECRET_DOMAIN_BLOG}"]}'
ed=$(flux-local build hr external-dns-cloudflare -n network --path kubernetes/flux/cluster 2>/dev/null \
  | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].args[]' | grep -E '^--managed-record-types' | sed 's/--managed-record-types=//' | sort | tr '\n' ',')
check "external-dns-managed-types" "$ed" "A,AAAA,CNAME,SRV,"
exit $fail
