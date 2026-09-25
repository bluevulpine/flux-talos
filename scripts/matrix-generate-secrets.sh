#!/usr/bin/env bash
#
# matrix-generate-secrets.sh
#
# Populates OpenBao secret/matrix with every secret the ESS matrix-stack chart
# needs (kubernetes/apps/matrix/matrix-stack). The chart's own initSecrets
# generator is disabled so that these live in OpenBao, not only in-cluster.
#
# Idempotent: a field that already exists is NEVER overwritten, so re-running is
# always safe. That matters most for Synapse__SigningKey — replacing it changes
# the server's federation identity.
#
# Formats match what the chart's generator (matrix-tools) would produce, except
# the MAS private keys, which are PEM instead of DER so they survive the
# ExternalSecret text template. MAS loads PKCS#1, PKCS#8 and SEC1 PEM.
#
# Not generated (they come from Authentik): Mas__Authentik__ClientId and
# Mas__Authentik__ClientSecret. The script reports if they are missing.
#
# Prerequisites: bao (authenticated, BAO_ADDR set), OpenSSL 3 (not LibreSSL:
# the ed25519 signing key needs `genpkey -algorithm ed25519`).
#
# Usage:
#   ./scripts/matrix-generate-secrets.sh [--dry-run]

set -euo pipefail

readonly BAO_PATH="secret/matrix"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Only a definite "not found" may count as missing. Any other failure (wrong
# BAO_ADDR, expired token, permission denied on read) must abort: treating it as
# "missing" would regenerate — and on write, overwrite — fields that exist, the
# Synapse signing key included.
bao token lookup >/dev/null 2>&1 ||
    die "bao cannot reach/authenticate to ${BAO_ADDR:-its default 127.0.0.1:8200}. Set BAO_ADDR (e.g. http://openbao.derekjacobs.dev) and run 'bao login'."

path_exists=false
if out="$(bao kv get "${BAO_PATH}" 2>&1)"; then
    path_exists=true
elif [[ "${out}" != *"No value found"* ]]; then
    die "cannot read ${BAO_PATH}: ${out}"
fi

has_field() {
    local out
    ${path_exists} || return 1
    if out="$(bao kv get -field="$1" "${BAO_PATH}" 2>&1)"; then
        return 0
    fi
    [[ "${out}" == *"not present in secret"* ]] && return 1
    die "cannot read ${BAO_PATH} field $1: ${out}"
}

rand_alnum() { # length
    # No `tr </dev/urandom | head`: head closing the pipe early is a SIGPIPE (141)
    # that pipefail turns into a script abort inside an assignment.
    local s=""
    while ((${#s} < $1)); do
        s+="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${s:0:$1}"
}

# 32 chars from [A-Za-z0-9] — the chart's `rand32`. Also safe inside the single-
# quoted SQL literal postgres-init builds for the database passwords.
rand32() { rand_alnum 32; }

# "ed25519 a_XXXX <unpadded base64 of the 32-byte seed>", the format Synapse's
# signing_key_path expects.
signing_key() {
    local der version
    der="${tmp}/ed25519.der"
    openssl genpkey -algorithm ed25519 -outform DER -out "${der}"
    version="a_$(rand_alnum 4)"
    # The PKCS#8 DER of an ed25519 key ends with the 32-byte seed.
    printf 'ed25519 %s %s\n' "${version}" "$(tail -c 32 "${der}" | base64 | tr -d '=\n')"
}

declare -a args=()
queue() { # field, value-or-@file
    if has_field "$1"; then
        echo "keep      $1"
    else
        echo "generate  $1"
        args+=("$1=$2")
    fi
}

queue Synapse__Postgres__Password "$(rand32)"
queue Mas__Postgres__Password "$(rand32)"
queue Synapse__Macaroon "$(rand32)"
queue Synapse__RegistrationSharedSecret "$(rand32)"
queue Mas__SynapseSharedSecret "$(rand32)"
queue Mas__EncryptionSecret "$(openssl rand -hex 32)"

if ! has_field Synapse__SigningKey; then
    signing_key >"${tmp}/signing.key"
fi
queue Synapse__SigningKey "@${tmp}/signing.key"

if ! has_field Mas__Keys__Rsa; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "${tmp}/rsa.pem" 2>/dev/null
fi
queue Mas__Keys__Rsa "@${tmp}/rsa.pem"

if ! has_field Mas__Keys__EcdsaPrime256v1; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${tmp}/ecdsa.pem"
fi
queue Mas__Keys__EcdsaPrime256v1 "@${tmp}/ecdsa.pem"

for field in Mas__Authentik__ClientId Mas__Authentik__ClientSecret; do
    has_field "${field}" || echo "MISSING   ${field}  (create the Authentik provider, then: bao kv patch ${BAO_PATH} ${field}=...)"
done

if ((${#args[@]} == 0)); then
    echo "Nothing to generate."
    exit 0
fi

if ${DRY_RUN}; then
    echo "--dry-run: not writing ${#args[@]} field(s)."
    exit 0
fi

# patch, never put: put would replace the whole secret and drop existing fields.
if ${path_exists}; then
    bao kv patch "${BAO_PATH}" "${args[@]}" >/dev/null
else
    bao kv put "${BAO_PATH}" "${args[@]}" >/dev/null
fi
echo "Wrote ${#args[@]} field(s) to ${BAO_PATH}."
