The secret `mosquitto` should contain the following keys.

> **⚠️ The users below (`godmode`, `basicaccess`, `neato`) are ILLUSTRATIVE
> EXAMPLES of the file *format* — they are NOT the live broker users.** Do not
> assume any of them exists. This has caused real bugs (a publisher configured
> against a nonexistent `basicaccess` user). To see the users that actually
> exist before referencing one:
>
> ```bash
> kubectl -n home get secret mosquitto-secret \
>   -o jsonpath='{.data.passwd\.conf}' | base64 -d | cut -d: -f1   # usernames
> kubectl -n home get secret mosquitto-secret \
>   -o jsonpath='{.data.acl\.conf}' | base64 -d                    # who can write where
> ```
>
> The general-purpose publisher is `mqtt_publisher` (`topic readwrite #`); the
> superuser is `bluevulpine_god`. Prefer a dedicated, ACL-scoped user per app
> (see `minnkota-collector`, `vault-power`) over reusing a broad one.

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
