{{- /*
  brokkr volumes on the AirDisk: capped EPHEMERAL and IMAGECACHE, plus LUKS2 user volume
  data-1. data-2 is on a different disk per node, so it is in node/<host>/. Do not define
  a same-named document in two layers: a later layer overlaying a partial document drops
  fields (measured; see the spec).
  The LUKS passphrase is topf.yaml `data.volumeKey` (was the SECRET_VOLUME_KEY placeholder in talconfig.yaml).
*/ -}}
{{ if hasPrefix "brokkr" .Node.Host -}}
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: disk.model == "AirDisk 1TB SSD"
  grow: false
  maxSize: 100GiB
---
apiVersion: v1alpha1
kind: VolumeConfig
name: IMAGECACHE
provisioning:
  diskSelector:
    match: disk.model == "AirDisk 1TB SSD"
  grow: false
  maxSize: 100GiB
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: data-1
provisioning:
  diskSelector:
    match: disk.model == "AirDisk 1TB SSD"
  grow: true
  minSize: 100GiB
filesystem:
  type: xfs
encryption:
  provider: luks2
  keys:
    - slot: 0
      tpm: {}
    - slot: 1
      static:
        passphrase: {{ .Data.volumeKey | toJson }}
{{- end }}
