{{- /* data-2 lives on this node's own second disk, hence the per-node file. */ -}}
apiVersion: v1alpha1
kind: UserVolumeConfig
name: data-2
provisioning:
  diskSelector:
    match: disk.model == "WD_BLACK SN770 2TB"
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
