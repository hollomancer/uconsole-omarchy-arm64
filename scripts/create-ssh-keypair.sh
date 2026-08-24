#!/usr/bin/env bash

# Create a dedicated passphrase-protected Ed25519 keypair for uConsole admin
# access. The passphrase is handled only by ssh-keygen on the controlling TTY.

set -u
set -o pipefail
set +x
umask 077

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve script directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

PRIVATE_KEY=''
PUBLIC_KEY=''
STAGING_DIR=''
STAGING_PRIVATE=''
STAGING_PUBLIC=''
GENERATION_COMPLETE=0
PRIVATE_PUBLISHED=0
PUBLIC_PUBLISHED=0

usage() {
  printf '%s\n' \
    'Usage: scripts/create-ssh-keypair.sh --output-private-key FILE' \
    '' \
    'Creates a dedicated Ed25519 keypair with 64 KDF rounds. ssh-keygen prompts' \
    'for the passphrase on the controlling terminal; an empty passphrase is' \
    'rejected. The private key and adjacent .pub file must be new and outside' \
    'this repository. The output directory must deny group/other writes. No' \
    'passphrase option or non-interactive mode is accepted.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

cleanup_incomplete() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $GENERATION_COMPLETE -eq 0 ]]; then
    if [[ $PUBLIC_PUBLISHED -eq 1 ]]; then rm -f -- "$PUBLIC_KEY" || status=1; fi
    if [[ $PRIVATE_PUBLISHED -eq 1 ]]; then rm -f -- "$PRIVATE_KEY" || status=1; fi
  fi
  if [[ -n "$STAGING_DIR" ]]; then
    if [[ -n "$STAGING_PRIVATE" || -n "$STAGING_PUBLIC" ]]; then
      rm -f -- "$STAGING_PRIVATE" "$STAGING_PUBLIC" || status=1
    fi
    rmdir -- "$STAGING_DIR" 2>/dev/null || status=1
  fi
  exit "$status"
}
trap cleanup_incomplete EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --output-private-key) (($# >= 2)) || die '--output-private-key requires a file'; PRIVATE_KEY=$2; shift 2 ;;
    --passphrase|--password|--password-file|--stdin|--non-interactive|-N)
      die "$1 is forbidden; ssh-keygen must prompt on the controlling terminal"
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PRIVATE_KEY" ]] || die '--output-private-key is required'
[[ "$PRIVATE_KEY" != *$'\n'* && "$PRIVATE_KEY" != *,* ]] || die 'output path contains a forbidden character'
PRIVATE_PARENT=${PRIVATE_KEY%/*}
PRIVATE_NAME=${PRIVATE_KEY##*/}
[[ "$PRIVATE_PARENT" != "$PRIVATE_KEY" ]] || PRIVATE_PARENT=.
[[ "$PRIVATE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$PRIVATE_NAME" != *.pub ]] || die 'private-key filename is unsafe'
[[ -d "$PRIVATE_PARENT" && ! -L "$PRIVATE_PARENT" ]] || die 'output parent is missing or a symlink'
PRIVATE_PARENT=$(cd -- "$PRIVATE_PARENT" && pwd -P) || die 'unable to resolve output parent'
if stat -c '%a' "$PRIVATE_PARENT" >/dev/null 2>&1; then
  PRIVATE_PARENT_MODE=$(stat -c '%a' "$PRIVATE_PARENT")
else
  PRIVATE_PARENT_MODE=$(stat -f '%Lp' "$PRIVATE_PARENT")
fi
[[ "$PRIVATE_PARENT_MODE" =~ ^[0-7]{3,4}$ ]] || die 'output parent has an invalid mode'
(( (8#$PRIVATE_PARENT_MODE & 8#022) == 0 )) || die 'output parent must not be writable by group or other'
PRIVATE_KEY="$PRIVATE_PARENT/$PRIVATE_NAME"
PUBLIC_KEY="${PRIVATE_KEY}.pub"
case "$PRIVATE_KEY" in
  "$REPO_ROOT"/*) die 'keypair must be outside the repository' ;;
  /dev/*|/proc/*|/sys/*) die 'unsafe output path' ;;
esac
[[ ! -e "$PRIVATE_KEY" && ! -L "$PRIVATE_KEY" ]] || die 'refusing an existing private-key path'
[[ ! -e "$PUBLIC_KEY" && ! -L "$PUBLIC_KEY" ]] || die 'refusing an existing public-key path'
[[ -r /dev/tty && -w /dev/tty ]] || die 'an interactive terminal is required'
for command_name in ln mktemp rmdir ssh-keygen; do command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"; done

STAGING_DIR=$(mktemp -d "$PRIVATE_PARENT/.uconsole-keypair.XXXXXX") || die 'unable to create private staging directory'
chmod 0700 "$STAGING_DIR" || die 'unable to secure private staging directory'
STAGING_PRIVATE="$STAGING_DIR/key"
STAGING_PUBLIC="${STAGING_PRIVATE}.pub"
ssh-keygen -q -t ed25519 -a 64 -C uconsole-admin -f "$STAGING_PRIVATE" || die 'ssh-keygen did not create the keypair'
[[ -f "$STAGING_PRIVATE" && ! -L "$STAGING_PRIVATE" && -f "$STAGING_PUBLIC" && ! -L "$STAGING_PUBLIC" ]] || die 'ssh-keygen output is incomplete or unsafe'

# Prove the private key cannot be opened with an empty passphrase. Public-key
# derivation output and the expected failure message are both discarded.
if ssh-keygen -y -P '' -f "$STAGING_PRIVATE" >/dev/null 2>&1; then
  die 'an empty passphrase is not allowed; no keypair was retained'
fi

chmod 0600 "$STAGING_PRIVATE" || die 'unable to set private-key mode 0600'
chmod 0644 "$STAGING_PUBLIC" || die 'unable to set public-key mode 0644'
KEY_INFO=$(ssh-keygen -lf "$STAGING_PUBLIC" -E sha256 2>&1) || die "public-key validation failed: $KEY_INFO"
KEY_FINGERPRINT=$(printf '%s\n' "$KEY_INFO" | awk 'NF >= 2 {print $2; exit}')
[[ "$KEY_FINGERPRINT" == SHA256:* ]] || die 'unable to derive public-key fingerprint'

# Hard-link publication is same-filesystem and no-clobber: ln(2) fails if an
# output appeared after the preliminary checks. The guarded cleanup removes
# only links created by this invocation if publishing the pair is interrupted.
ln "$STAGING_PRIVATE" "$PRIVATE_KEY" || die 'unable to publish the new private key without overwriting'
PRIVATE_PUBLISHED=1
ln "$STAGING_PUBLIC" "$PUBLIC_KEY" || die 'unable to publish the new public key without overwriting'
PUBLIC_PUBLISHED=1
rm -f -- "$STAGING_PRIVATE" "$STAGING_PUBLIC" || die 'unable to remove staged key links'
rmdir -- "$STAGING_DIR" || die 'unable to remove private staging directory'
STAGING_DIR=''
STAGING_PRIVATE=''
STAGING_PUBLIC=''
GENERATION_COMPLETE=1
printf '[PASS] dedicated SSH keypair created: %s + %s\n' "$PRIVATE_KEY" "$PUBLIC_KEY"
printf '[PASS] private key is passphrase-protected; public fingerprint=%s\n' "$KEY_FINGERPRINT"
