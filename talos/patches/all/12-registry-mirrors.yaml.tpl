# containerd registry mirrors for the Nexus pull-through cache. Spegel (with
# prependExisting: true) prepends itself to these, giving Spegel -> Nexus -> upstream.
#
# The domain comes from topf.yaml `data.domain` (was the SECRET_DOMAIN placeholder in talconfig.yaml). topf does NOT
# substitute shell-style placeholders: a literal one here would render verbatim, with no error.
machine:
  registries:
    mirrors:
      docker.io:
        endpoints:
          - https://docker-hub.nexus.{{ .Data.domain }}
      ghcr.io:
        endpoints:
          - https://ghcr.nexus.{{ .Data.domain }}
      quay.io:
        endpoints:
          - https://quay.nexus.{{ .Data.domain }}
      lscr.io:
        endpoints:
          - https://lscr.nexus.{{ .Data.domain }}
      gcr.io:
        endpoints:
          - https://gcr.nexus.{{ .Data.domain }}
      registry.k8s.io:
        endpoints:
          - https://registry-k8s.nexus.{{ .Data.domain }}
      public.ecr.aws:
        endpoints:
          - https://ecr.nexus.{{ .Data.domain }}
      cgr.dev:
        endpoints:
          - https://cgr.nexus.{{ .Data.domain }}
