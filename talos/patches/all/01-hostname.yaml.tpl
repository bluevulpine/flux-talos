# topf emits `HostnameConfig` with `auto: stable`; pin the configured hostname instead,
# as talhelper did.
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
