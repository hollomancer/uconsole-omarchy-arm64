#!/usr/bin/env bash

# Create the private NetworkManager keyfile consumed by configure-base-system.
# SSID and passphrase are read from /dev/tty; the passphrase is never accepted
# in arguments, written to an intermediate file, or printed.

set -u
set -o pipefail
set +x
umask 077

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve script directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi
# shellcheck source=scripts/lib/networkmanager-keyfile.sh
source "$SCRIPT_DIR/lib/networkmanager-keyfile.sh"

OUTPUT=''
KEY_MGMT=wpa-psk
HIDDEN=false

usage() {
  printf '%s\n' \
    'Usage: scripts/create-wifi-keyfile.sh --output FILE [options]' \
    '' \
    'Options:' \
    '  --key-mgmt wpa-psk|sae  WPA2/WPA3 Personal (default) or WPA3-only' \
    '  --hidden                 Mark the SSID as hidden' \
    '  --help                   Show this help' \
    '' \
    'Prompts for the SSID and twice for its passphrase on /dev/tty, then creates' \
    'one new mode-0600 .nmconnection file outside this repository. Plaintext' \
    'passphrases are never accepted as arguments, printed, or staged in a file.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --output) (($# >= 2)) || die '--output requires a file'; OUTPUT=$2; shift 2 ;;
    --key-mgmt) (($# >= 2)) || die '--key-mgmt requires a value'; KEY_MGMT=$2; shift 2 ;;
    --hidden) HIDDEN=true; shift ;;
    --ssid|--psk|--password|--password-file|--stdin|--non-interactive)
      die "$1 is forbidden; SSID and passphrase are read only from /dev/tty"
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$KEY_MGMT" == wpa-psk || "$KEY_MGMT" == sae ]] || die '--key-mgmt must be wpa-psk or sae'
[[ -n "$OUTPUT" ]] || die '--output is required'
[[ "$OUTPUT" != *$'\n'* && "$OUTPUT" != *,* ]] || die 'output path contains a forbidden character'
OUTPUT_PARENT=${OUTPUT%/*}
OUTPUT_NAME=${OUTPUT##*/}
[[ "$OUTPUT_PARENT" != "$OUTPUT" ]] || OUTPUT_PARENT=.
[[ "$OUTPUT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.nmconnection$ ]] || die 'output filename must be a safe .nmconnection name'
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || die 'output parent is missing or a symlink'
OUTPUT_PARENT=$(cd -- "$OUTPUT_PARENT" && pwd -P) || die 'unable to resolve output parent'
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
case "$OUTPUT" in
  "$REPO_ROOT"/*) die 'output must be outside the repository' ;;
  /dev/*|/proc/*|/sys/*) die 'unsafe output path' ;;
esac
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die 'refusing an existing output path'
[[ -r /dev/tty && -w /dev/tty ]] || die 'an interactive terminal is required'
for command_name in iconv uuidgen wc; do command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"; done

SSID=''
FIRST_PSK=''
SECOND_PSK=''
printf 'Wi-Fi SSID: ' >/dev/tty
IFS= read -r SSID </dev/tty || die 'unable to read SSID'
printf 'Wi-Fi passphrase: ' >/dev/tty
IFS= read -r -s FIRST_PSK </dev/tty || die 'unable to read first passphrase'
printf '\nRepeat Wi-Fi passphrase: ' >/dev/tty
IFS= read -r -s SECOND_PSK </dev/tty || die 'unable to read repeated passphrase'
printf '\n' >/dev/tty

[[ -n "$SSID" ]] || die 'SSID must not be empty'
[[ "$SSID" != *$'\r'* && "$SSID" != *$'\t'* ]] || die 'SSID contains an unsupported control character'
SSID_BYTES=$(printf '%s' "$SSID" | wc -c | tr -d ' ')
[[ "$SSID_BYTES" =~ ^[0-9]+$ && "$SSID_BYTES" -ge 1 && "$SSID_BYTES" -le 32 ]] || die 'SSID must contain 1 to 32 UTF-8 bytes'
printf '%s' "$SSID" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || die 'SSID must be valid UTF-8'

[[ -n "$FIRST_PSK" ]] || die 'passphrase must not be empty'
[[ "$FIRST_PSK" == "$SECOND_PSK" ]] || die 'passphrase entries do not match'
[[ "$FIRST_PSK" != *$'\r'* && "$FIRST_PSK" != *$'\n'* && "$FIRST_PSK" != *$'\t'* ]] || die 'passphrase contains an unsupported control character'
PSK_BYTES=$(printf '%s' "$FIRST_PSK" | wc -c | tr -d ' ')
[[ "$PSK_BYTES" =~ ^[0-9]+$ ]] || die 'unable to measure passphrase'
if [[ "$KEY_MGMT" == wpa-psk ]]; then
  if [[ "$PSK_BYTES" -eq 64 && "$FIRST_PSK" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    :
  elif [[ "$PSK_BYTES" -ge 8 && "$PSK_BYTES" -le 63 ]] && printf '%s' "$FIRST_PSK" | LC_ALL=C grep -Eq '^[ -~]+$'; then
    :
  else
    die 'WPA Personal requires 8-63 printable ASCII characters or 64 hexadecimal characters'
  fi
else
  ((PSK_BYTES <= 1024)) || die 'SAE passphrase exceeds the audited 1024-byte input bound'
  printf '%s' "$FIRST_PSK" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || die 'SAE passphrase must be valid UTF-8'
fi

SSID_ESCAPED=$(uconsole_nm_keyfile_escape "$SSID")
PSK_ESCAPED=$(uconsole_nm_keyfile_escape "$FIRST_PSK")
PROFILE_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]') || die 'unable to create connection UUID'
[[ "$PROFILE_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die 'generated connection UUID is invalid'

if ! (set -o noclobber; {
  printf '%s\n' \
    '[connection]' \
    'id=uconsole-bootstrap' \
    "uuid=$PROFILE_UUID" \
    'type=wifi' \
    'autoconnect=true' \
    '' \
    '[wifi]' \
    'mode=infrastructure' \
    "ssid=$SSID_ESCAPED"
  if [[ "$HIDDEN" == true ]]; then printf 'hidden=true\n'; fi
  printf '%s\n' \
    'security=wifi-security' \
    '' \
    '[wifi-security]' \
    "key-mgmt=$KEY_MGMT" \
    "psk=$PSK_ESCAPED" \
    'psk-flags=0' \
    '' \
    '[ipv4]' \
    'method=auto' \
    '' \
    '[ipv6]' \
    'method=auto'
} > "$OUTPUT"); then
  SSID=''; FIRST_PSK=''; SECOND_PSK=''; SSID_ESCAPED=''; PSK_ESCAPED=''
  die 'unable to create the new output file'
fi
SSID=''; FIRST_PSK=''; SECOND_PSK=''; SSID_ESCAPED=''; PSK_ESCAPED=''
chmod 0600 "$OUTPUT" || die 'unable to set output mode 0600'
printf '[PASS] private NetworkManager profile created: %s (mode 0600, key-mgmt=%s, hidden=%s)\n' "$OUTPUT" "$KEY_MGMT" "$HIDDEN"
