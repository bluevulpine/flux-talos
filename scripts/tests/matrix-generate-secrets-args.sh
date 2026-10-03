#!/bin/bash
# Argument parsing for matrix-generate-secrets.sh, against a FAKE bao on PATH.
# The fake records the path of every `kv get` and makes every field "missing",
# so the script reaches its final dry-run exit without touching OpenBao.
#
# /bin/bash on purpose: a zsh -c would re-read ~/.zshenv and put the REAL bao
# first on PATH (reference_zsh_c_resets_fake_path).
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/matrix-generate-secrets.sh"
readonly SCRIPT
fake="$(mktemp -d)"
trap 'rm -rf "${fake}"' EXIT

cat >"${fake}/bao" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "token lookup") exit 0 ;;
  "kv get")
    for a in "$@"; do [[ "$a" == secret/* ]] && echo "$a" >>"${BAO_FAKE_LOG}"; done
    echo "No value found at ${!#}" >&2; exit 2 ;;
  "kv put"|"kv patch") echo "FAKE BAO REFUSES WRITES" >&2; exit 99 ;;
esac
exit 0
EOF
chmod +x "${fake}/bao"

run() { # expected-path, args...
  local want="$1"; shift
  export BAO_FAKE_LOG="${fake}/log"; : >"${BAO_FAKE_LOG}"
  PATH="${fake}:${PATH}" "${SCRIPT}" "$@" >/dev/null
  local got; got="$(sort -u "${BAO_FAKE_LOG}")"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: args [$*] read path [${got}], want [${want}]" >&2; exit 1
  fi
  echo "ok:   args [$*] -> ${want}"
}

run secret/matrix             --dry-run
run secret/matrix-bluevulpine --dry-run secret/matrix-bluevulpine
run secret/matrix-bluevulpine secret/matrix-bluevulpine --dry-run

# Unknown flags must abort, not be taken as a path.
if PATH="${fake}:${PATH}" "${SCRIPT}" --dryrun >/dev/null 2>&1; then
  echo "FAIL: unknown flag --dryrun was accepted" >&2; exit 1
fi
echo "ok:   unknown flag rejected"
