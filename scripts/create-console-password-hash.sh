#!/usr/bin/env bash

# Create the private SHA-512 crypt file consumed by configure-base-system.sh.
# The password is read twice from /dev/tty and sent over stdin to the pinned
# offline ARM64 builder, avoiding host OpenSSL feature differences.

set -u
set -o pipefail
# Disable inherited tracing before any password is read into a shell variable.
set +x
umask 077

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve script directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

OUTPUT=''
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: scripts/create-console-password-hash.sh --output FILE' \
    '' \
    'Prompts twice on /dev/tty and creates one new mode-0600 SHA-512 crypt file.' \
    'The output must be outside this repository. Existing files are refused.' \
    'The plaintext password is never an argument, file, log message or image layer.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --output) (($# >= 2)) || die '--output requires a file'; OUTPUT=$2; shift 2 ;;
    --password|--password-file|--hash|--stdin|--non-interactive) die "$1 is forbidden; the password is read only from /dev/tty" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$OUTPUT" ]] || die '--output is required'
[[ "$OUTPUT" != *$'\n'* && "$OUTPUT" != *,* ]] || die 'output path contains a forbidden character'
OUTPUT_PARENT=${OUTPUT%/*}
OUTPUT_NAME=${OUTPUT##*/}
[[ "$OUTPUT_PARENT" != "$OUTPUT" ]] || OUTPUT_PARENT=.
[[ "$OUTPUT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'output filename contains unsafe characters'
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || die 'output parent is missing or a symlink'
OUTPUT_PARENT=$(cd -- "$OUTPUT_PARENT" && pwd -P) || die 'unable to resolve output parent'
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
case "$OUTPUT" in
  "$REPO_ROOT"/*) die 'output must be outside the repository' ;;
  /dev/*|/proc/*|/sys/*) die 'unsafe output path' ;;
esac
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die 'refusing an existing output path'
[[ -r /dev/tty && -w /dev/tty ]] || die 'an interactive terminal is required'
command -v docker >/dev/null 2>&1 || die 'docker is required for the pinned SHA-512 crypt implementation'

FIRST_PASSWORD=''
SECOND_PASSWORD=''
printf 'Local console recovery password: ' >/dev/tty
IFS= read -r -s FIRST_PASSWORD </dev/tty || die 'unable to read first password'
printf '\nRepeat local console recovery password: ' >/dev/tty
IFS= read -r -s SECOND_PASSWORD </dev/tty || die 'unable to read repeated password'
printf '\n' >/dev/tty
[[ -n "$FIRST_PASSWORD" ]] || die 'password must not be empty'
[[ "$FIRST_PASSWORD" == "$SECOND_PASSWORD" ]] || die 'password entries do not match'

HASH=''
HASH=$(printf '%s\n' "$FIRST_PASSWORD" | docker run --rm -i --read-only --log-driver none \
  --platform linux/arm64 --network none "$IMAGE" openssl passwd -6 -stdin) || {
  FIRST_PASSWORD=''
  SECOND_PASSWORD=''
  die 'pinned SHA-512 crypt generation failed'
}
FIRST_PASSWORD=''
SECOND_PASSWORD=''
[[ "$HASH" == '$6$'* && ${#HASH} -ge 20 && ${#HASH} -le 512 ]] || die 'generated hash has an unexpected format'
[[ "$HASH" != *:* && "$HASH" != *[[:space:]]* ]] || die 'generated hash contains a forbidden character'

if ! (set -o noclobber; printf '%s\n' "$HASH" > "$OUTPUT"); then
  HASH=''
  die 'unable to create the new output file atomically'
fi
HASH=''
chmod 0600 "$OUTPUT" || die 'unable to set output mode 0600'
printf '[PASS] console password hash created: %s (mode 0600, SHA-512 crypt)\n' "$OUTPUT"
