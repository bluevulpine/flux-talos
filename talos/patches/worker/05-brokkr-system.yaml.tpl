{{- /* brokkr (AMD mini-PC) workers: hugepages and PCI passthrough modules. */ -}}
{{ if hasPrefix "brokkr" .Node.Host -}}
machine:
  sysctls:
    vm.nr_hugepages: "1024"
  kernel:
    modules:
      - name: vfio_pci
      - name: uio_pci_generic
{{- end }}
