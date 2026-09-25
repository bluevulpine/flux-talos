{{- /*
  jormungandr1-3 select their NIC by hardware address (the Raspberry Pi Foundation OUI),
  so the interface name does not matter. jormungandr4 names `end0` directly and lives in
  node/jormungandr4/; see the spec's deferred jormungandr1-4 convergence.
*/ -}}
{{ if regexMatch "^jormungandr[123]$" .Node.Host -}}
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("e4:5f:01:*", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
mtu: 1500
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: ethSel0
{{- end }}
