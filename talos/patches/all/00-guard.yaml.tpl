{{- /*
  Guard: renders nothing for a known node, and FAILS THE RENDER for anything else.

  The group patches in worker/ are gated on hostname prefixes, so a node with an unexpected
  name (or role) would render without error and without its network, install disk or taints;
  e.g. a `brokkr04` would get bond0 VLANs but no BondConfig. That passes `talosctl validate`.
  Failing loudly here turns that into an error at render time.

  It also rejects a node with no schematicId. topf then silently falls back to Talos's DEFAULT
  schematic, which has no system extensions (no iSCSI, NFS tooling or tailscale): it installs
  and validates, then breaks storage at the next upgrade.

  To add or rename a node: add it to the map below, then read worker/ and node/ and give it
  whatever those gates and per-node files give its siblings (a brokkr needs
  node/<host>/01-bond.yaml and 02-data-2.yaml.tpl; a Pi needs the right network gate).
*/ -}}
{{- $nodes := dict
      "freyja01"     "control-plane"
      "jormungandr1" "worker"
      "jormungandr2" "worker"
      "jormungandr3" "worker"
      "jormungandr4" "worker"
      "brokkr01"     "worker"
      "brokkr02"     "worker"
      "brokkr03"     "worker" -}}
{{- if not (hasKey $nodes .Node.Host) -}}
  {{- fail (printf "talos/patches/all/00-guard.yaml.tpl: unknown node %q; see the comment there before adding it" .Node.Host) -}}
{{- end -}}
{{- if ne (get $nodes .Node.Host) .Node.Role -}}
  {{- fail (printf "talos/patches/all/00-guard.yaml.tpl: %s is expected to be %q but topf.yaml says %q; the worker/ and control-plane/ patches would not fit" .Node.Host (get $nodes .Node.Host) .Node.Role) -}}
{{- end -}}
{{- if or (not .SchematicID) (eq .SchematicID "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba") -}}
  {{- fail (printf "talos/patches/all/00-guard.yaml.tpl: %s has no schematicId (or the default, extension-less one); set one in topf.yaml" .Node.Host) -}}
{{- end -}}
