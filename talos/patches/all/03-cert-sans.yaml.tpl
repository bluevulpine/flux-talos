{{- /*
  One list of certificate SANs (talconfig.yaml's additionalApiServerCertSans and
  additionalMachineCertSans were a single shared list). Every node gets it as
  machine.certSANs; only the control plane also gets it as the API server's certSANs, because
  talhelper never wrote cluster.apiServer.certSANs to workers.
*/ -}}
{{- $sans := list "10.0.10.30" "127.0.0.1" "talos.flyingfox-decibel.ts.net" "k8s.internal" -}}
{{- /* 127.0.0.1 is KubePrism. */ -}}
machine:
  certSANs: {{ toJson $sans }}
{{- if eq .Node.Role "control-plane" }}
cluster:
  apiServer:
    certSANs: {{ toJson $sans }}
{{- end }}
