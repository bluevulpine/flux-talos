The secret `mosquitto` should contain the following keys:

```yaml
mosquitto.conf: |
  # the broker settings.
  per_listener_settings true
  autosave_interval 60
  connection_messages true
  persistence true
  persistence_location /mosquitto/data
  log_dest stdout
  log_dest file /mosquitto/log/mosquitto.log
  listener 1883
  allow_anonymous false
  password_file /mosquitto/config/passwd.conf
  acl_file /mosquitto/config/acl.conf
  listener 8883
  allow_anonymous false
  certfile /mosquitto/tls/tls.crt
  keyfile  /mosquitto/tls/tls.key
  password_file /mosquitto/config/passwd.conf
  acl_file /mosquitto/config/acl.conf

acl.conf: |
  # root access
  user godmode
  topic readwrite #
  # internal IOT
  user basicaccess
  topic deny $SYS/#
  topic readwrite #
  # or get more specific
  user neato
  topic write neato/+/rx
  topic read  neato/+/tx

passwd.conf: |
  # username:password pairs. will be hashed by helmrelease script.
  godmode:supersecret
  basicaccess:basic
  neato:neato
