#!/usr/bin/env bash
# Real-secrets gate for the talhelper -> topf migration. Run by the OPERATOR; needs the age key.
# Migration verification tool; delete with talconfig.yaml in Phase 7.
#
# Prints only SAME / DIFFERENT / OK / FAIL and line counts. It never prints a secret value, and
# the render it makes (plaintext, PKI included) lives in a mode-700 temp dir removed on exit.
#
#   SOPS_AGE_KEY_FILE=~/Repositories/flux-talos/age.key talos/tools/verify-real.sh [baseline_dir]
#
# baseline_dir defaults to the live-applied configs in the main checkout, which Phase 0 showed
# are byte-identical to what talhelper 3.1.17 generates today.
#
# What it proves that the synthetic-secrets comparison could not:
#   1. the PKI bundle topf reads is the one talhelper used (talsecret.sops.yaml == secrets.sops.yaml)
#   2. the three values moved into topf.yaml `data:` equal the talenv.sops.yaml originals
#   3. a render with the real secrets equals the baseline for every node, HMAC-compared: the
#      PKI, tokens, Tailscale key, LUKS passphrase (incl. that quoting did not mangle it) and
#      registry domain all match, and "present vs blank" cannot compare equal.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="${TALOS_DIR:-$(cd "$HERE/.." && pwd)}"
TOPF="${TOPF:-$TALOS_DIR/../.bin/topf}"
BASELINE="${1:-$HOME/Repositories/flux-talos/talos/clusterconfig}"
: "${SOPS_AGE_KEY_FILE:?set SOPS_AGE_KEY_FILE to the age key}"
for c in sops yq openssl python3; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
[[ -x "$TOPF" ]] || { echo "topf not found at $TOPF (go install it into .bin/)" >&2; exit 2; }
[[ -d "$BASELINE" ]] || { echo "baseline dir not found: $BASELINE" >&2; exit 2; }

rc=0
same() { if "$@"; then echo "  SAME"; else echo "  DIFFERENT"; rc=1; fi; }
canon() { yq -o=json -I=0 'sort_keys(..)' -; }

echo "1. PKI bundle: talsecret.sops.yaml vs secrets.sops.yaml"
same cmp -s <(sops -d "$TALOS_DIR/talsecret.sops.yaml" | canon) <(sops -d "$TALOS_DIR/secrets.sops.yaml" | canon)

for pair in SECRET_TS_AUTHKEY:tsAuthKey SECRET_VOLUME_KEY:volumeKey SECRET_DOMAIN:domain; do
  echo "2. talenv ${pair%%:*} vs topf.yaml data.${pair##*:}"
  same cmp -s <(sops -d --extract "[\"${pair%%:*}\"]" "$TALOS_DIR/talenv.sops.yaml") \
              <(sops -d --extract "[\"data\"][\"${pair##*:}\"]" "$TALOS_DIR/topf.yaml")
done

echo "3. real-secrets render vs baseline, HMAC-compared"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
# topf's error text is deliberately NOT echoed: an error about a field can quote its value (a
# passphrase, the Tailscale key), and this script promises never to print one. Reproduce it
# deliberately and look yourself: (cd talos && ../.bin/topf render -o "$(mktemp -d)")
( umask 077; cd "$TALOS_DIR" && "$TOPF" render -o "$out" </dev/null >/dev/null 2>/dev/null ) \
  || { echo "  render FAILED (topf's output withheld; it may quote a secret). Reproduce by hand:"; \
       echo "    (cd $TALOS_DIR && $TOPF render -o \"\$(mktemp -d)\")"; exit 1; }
"$HERE/compare.sh" "$BASELINE" "$out" --hash || rc=1

echo
(( rc == 0 )) && echo "RESULT: OK. Real secrets and rendered config match the baseline." || { echo "RESULT: FAIL. Do not apply anything." >&2; exit 1; }
