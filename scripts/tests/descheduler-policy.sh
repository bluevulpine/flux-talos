#!/bin/bash
# Descheduler policy guard: CoreDNS (and every system-critical pod) must not be evicted.
# Background: v0.36 kept evicting kube-system/coredns (system-cluster-critical, priority 2e9) via
# LowNodeUtilization even with the deprecated `evictSystemCriticalPods: false` set; zero "system
# critical priority" rejections appeared in 6h of --v=3 logs. Fix: the v0.36 `podProtections`
# form (SystemCriticalPods stays a default protection) + exclude kube-system from rebalancing.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
F=kubernetes/apps/kube-system/descheduler/app/helmrelease.yaml
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
pc='.spec.values.deschedulerPolicy.profiles[0].pluginConfig[]'
de=$(yq -o=json "$pc | select(.name==\"DefaultEvictor\") | .args" "$F")
check "no deprecated evictor keys" "$(echo "$de" | jq -c '[keys[] | select(test("^(evict|ignore)"))]')" '[]'
check "podProtections.defaultDisabled" "$(echo "$de" | jq -c '.podProtections.defaultDisabled | sort')" '["FailedBarePods","PodsWithLocalStorage"]'
check "SystemCriticalPods NOT disabled" "$(echo "$de" | jq -c '[.podProtections.defaultDisabled[]? | select(.=="SystemCriticalPods")] | length')" '0'
check "DaemonSetPods NOT disabled" "$(echo "$de" | jq -c '[.podProtections.defaultDisabled[]? | select(.=="DaemonSetPods")] | length')" '0'
check "nodeFit kept" "$(echo "$de" | jq -c '.nodeFit')" 'true'
lnu=$(yq -o=json "$pc | select(.name==\"LowNodeUtilization\") | .args" "$F")
check "LowNodeUtilization excludes kube-system" "$(echo "$lnu" | jq -c '.evictableNamespaces.exclude // [] | index("kube-system") != null')" 'true'
check "LowNodeUtilization thresholds kept" "$(echo "$lnu" | jq -c '[.thresholds.cpu,.targetThresholds.cpu]')" '[20,50]'
exit $fail
