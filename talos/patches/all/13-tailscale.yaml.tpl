# The key comes from topf.yaml `data.tsAuthKey` (was the SECRET_TS_AUTHKEY placeholder in talconfig.yaml). It is only
# consulted when a node registers with the tailnet; see the spec on expiry. `toJson` quotes it:
# unquoted, a `#` truncates the value and a leading-zero number is read as octal.
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - {{ printf "TS_AUTHKEY=%s" .Data.tsAuthKey | toJson }}
