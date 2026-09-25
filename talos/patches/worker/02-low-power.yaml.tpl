{{- /*
  Raspberry Pi workers (jormungandr*): tainted so only workloads that explicitly tolerate
  a Pi land on them. Gated on the hostname prefix, so this one file serves the group.
*/ -}}
{{ if hasPrefix "jormungandr" .Node.Host -}}
machine:
  nodeTaints:
    node.kubernetes.io/low-power: raspberry-pi:NoSchedule
  kubelet:
    extraConfig:
      registerWithTaints:
        - key: node.kubernetes.io/low-power
          value: raspberry-pi
          effect: NoSchedule
{{- end }}
