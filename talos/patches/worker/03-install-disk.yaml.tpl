{{- /*
  Install disk by hostname group. The Pis boot from a USB SSD at /dev/sda; brokkr installs
  to the AirDisk by model. freyja01 (/dev/vda) is in node/freyja01/.
*/ -}}
{{ if hasPrefix "jormungandr" .Node.Host -}}
machine:
  install:
    disk: /dev/sda
{{- else if hasPrefix "brokkr" .Node.Host -}}
machine:
  install:
    diskSelector:
      model: AirDisk 1TB SSD
{{- end }}
