{{- /*
  brokkr: 802.3ad bond0 (its member NICs differ per node, so BondConfig is in node/<host>/),
  DHCP on the bond, and VLANs 10/30/50 on top of it.
*/ -}}
{{ if hasPrefix "brokkr" .Node.Host -}}
apiVersion: v1alpha1
kind: DHCPv4Config
name: bond0
---
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.10
parent: bond0
vlanID: 10
mtu: 1500
---
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.30
parent: bond0
vlanID: 30
mtu: 1500
---
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.50
parent: bond0
vlanID: 50
mtu: 1500
{{- end }}
