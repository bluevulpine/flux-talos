# containerd registry mirrors: the zot pull-through cache on the TrueNAS host `vault`
# (docs/runbooks/zot-registry-mirror.md; it replaced the in-cluster Nexus on 2026-11-13).
# Spegel (prependExisting: true) prepends itself, giving Spegel -> zot -> upstream.
#
# Plain HTTP to the NAS IP, not a cluster hostname: nodes must reach the mirror during a cold
# bootstrap, before any gateway, certificate or cluster DNS exists, which is when Docker Hub's
# anonymous rate limit bites. zot is anonymous read-only, and containerd checks every blob
# against its digest.
#
# One zot instance serves every upstream under its own prefix, so each endpoint carries the
# full /v2/<prefix> path and overridePath stops containerd from adding its own /v2.
# No skipFallback: if the NAS is down, pulls go straight to the upstream instead of failing.
#
# RegistryMirrorConfig documents, not machine.registries, which Talos 1.12 deprecated.
# The registry list must match spegel.mirroredRegistries
# (kubernetes/apps/kube-system/spegel/app/helmrelease.yaml); a registry Spegel does not list
# loses this mirror when Spegel moves its hosts.toml into _backup/.
{{- range $registry := list "docker.io" "ghcr.io" "quay.io" "lscr.io" "gcr.io" "registry.k8s.io" "public.ecr.aws" "cgr.dev" }}
---
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: {{ $registry }}
endpoints:
  - url: http://10.0.10.11:5000/v2/{{ $registry }}
    overridePath: true
{{- end }}
