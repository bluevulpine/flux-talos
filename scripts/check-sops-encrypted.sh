#!/usr/bin/env bash
# Verify that the given SOPS files are ACTUALLY encrypted, not merely named or marked so.
#
# Why: gitleaks excludes *.sops.yaml by filename, so a plaintext file with that name, or a
# real encrypted file with a plaintext value added by hand (editor, `yq -i`) instead of by
# `sops`, would commit with no secret scanning at all. A bare `grep '^sops:'` is not enough:
# it passes a `sops: {}` stub and a mixed file.
#
# Rules (no decryption happens; needs only yq):
#   * exactly one YAML document, with a `sops` map that has a recipient and an ENC[...] mac
#   * every scalar in the encrypted scope is a string of the form ENC[AES256_GCM,...]
#       talos/topf.yaml              scope: .data           (the rest is deliberately cleartext)
#       kubernetes/**/*.sops.yaml    scope: .data, .stringData
#       any other *.sops.yaml        scope: the whole file except .sops
set -euo pipefail

command -v yq >/dev/null || { echo "check-sops-encrypted: yq is required" >&2; exit 1; }
rc=0
fail() { echo "$1: $2" >&2; rc=1; }

# yq expression: scalars in the selected scope that are not ENC[AES256_GCM,...] strings.
NOT_ENC='[.. | select(kind == "scalar") | select(tag != "!!null") | select((tag == "!!str" and test("^ENC\\[AES256_GCM,")) | not)] | length'

for f in "$@"; do
  [[ -f "$f" ]] || { fail "$f" "no such file"; continue; }

  docs=$(yq eval-all '[document_index] | length' "$f" | paste -sd+ - | bc)
  [[ "$docs" == "1" ]] || { fail "$f" "expected 1 YAML document, found $docs (a 2nd document can hide plaintext)"; continue; }

  if ! yq -e '(.sops | tag == "!!map") and (.sops.mac | tag == "!!str") and (.sops.mac | test("^ENC\\[")) and ((.sops.age // .sops.kms // .sops.pgp // .sops.gcp_kms // .sops.azure_kv // .sops.hc_vault // []) | length > 0)' "$f" >/dev/null 2>&1; then
    fail "$f" "no valid sops: block (need a recipient and an ENC[...] mac); is it plaintext?"; continue
  fi

  # Scopes are counted one at a time: `$scopes` holds one yq path expression per line.
  case "$f" in
    */talos/topf.yaml|talos/topf.yaml)
      scopes='.data'
      yq -e '.data | tag == "!!map" and length > 0' "$f" >/dev/null 2>&1 || { fail "$f" "no data: block to check"; continue; } ;;
    kubernetes/*.sops.yaml|*/kubernetes/*.sops.yaml)
      scopes=$'.data\n.stringData' ;;
    *) scopes='del(.sops)' ;;
  esac

  bad=0
  while IFS= read -r scope; do
    n=$(yq "($scope // {}) | $NOT_ENC" "$f" 2>/dev/null) || { fail "$f" "could not evaluate scope $scope"; n=1; }
    bad=$((bad + n))
  done <<< "$scopes"
  (( bad == 0 )) || fail "$f" "$bad value(s) in the encrypted scope are not ENC[AES256_GCM,...] ciphertext (plaintext added by hand?)"
done
exit $rc
