#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
HELPER="$REPO_ROOT/scripts/create-wifi-keyfile.sh"
KEYFILE_LIB="$REPO_ROOT/scripts/lib/networkmanager-keyfile.sh"

bash -n "$HELPER" "$KEYFILE_LIB"
# shellcheck source=scripts/lib/networkmanager-keyfile.sh
source "$KEYFILE_LIB"
[[ $(uconsole_nm_keyfile_escape 'plain') == 'plain' ]]
[[ $(uconsole_nm_keyfile_escape ' leading') == '\sleading' ]]
[[ $(uconsole_nm_keyfile_escape 'trailing ') == 'trailing\s' ]]
[[ $(uconsole_nm_keyfile_escape ' both ') == '\sboth\s' ]]
[[ $(uconsole_nm_keyfile_escape 'back\slash') == 'back\\slash' ]]
HELP_OUTPUT=$($HELPER --help)
grep -Fq 'mode-0600 .nmconnection file' <<< "$HELP_OUTPUT"
grep -Fq 'never accepted as arguments, printed, or staged in a file' <<< "$HELP_OUTPUT"
grep -Fq -- '--key-mgmt wpa-psk|sae' <<< "$HELP_OUTPUT"

for forbidden in --ssid --psk --password --password-file --stdin --non-interactive; do
  if "$HELPER" "$forbidden" >/dev/null 2>&1; then
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  else
    status=$?
    [[ $status -eq 2 ]] || { printf 'Expected %s to exit 2; observed %s\n' "$forbidden" "$status" >&2; exit 1; }
  fi
done
if "$HELPER" --output "$REPO_ROOT/private.nmconnection" >/dev/null 2>&1; then
  printf 'Expected repository output to be rejected\n' >&2
  exit 1
else
  status=$?
  [[ $status -eq 2 ]]
fi
[[ ! -e "$REPO_ROOT/private.nmconnection" ]]

grep -Fq 'read -r SSID </dev/tty' "$HELPER"
grep -Fq 'read -r -s FIRST_PSK </dev/tty' "$HELPER"
grep -Fq 'read -r -s SECOND_PSK </dev/tty' "$HELPER"
grep -Fq 'set +x' "$HELPER"
grep -Fq 'set -o noclobber' "$HELPER"
grep -Fq 'uconsole_nm_keyfile_escape "$FIRST_PSK"' "$HELPER"
! grep -Eq 'printf.*FIRST_PSK.*(>/dev/tty|[^|]$)' "$HELPER"

if command -v expect >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
  TEST_BASE=${TMPDIR:-/tmp}
  TEST_BASE=${TEST_BASE%/}
  TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-wifi-helper-test.XXXXXX")
  cleanup() {
    case "$TEST_TMP" in
      /tmp/uconsole-wifi-helper-test.*|/private/tmp/uconsole-wifi-helper-test.*|/var/folders/*/T/uconsole-wifi-helper-test.*|/private/var/folders/*/T/uconsole-wifi-helper-test.*) rm -rf -- "$TEST_TMP" ;;
      *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
    esac
  }
  trap cleanup EXIT
  OUTPUT="$TEST_TMP/bootstrap.nmconnection"
  HELPER="$HELPER" OUTPUT="$OUTPUT" expect <<'EXPECT'
log_user 0
set timeout 10
spawn $env(HELPER) --output $env(OUTPUT)
expect "Wi-Fi SSID: "
send -- " fixture-network \\ primary \r"
expect "Wi-Fi passphrase: "
send -- "fixture-password\r"
expect "Repeat Wi-Fi passphrase: "
send -- "fixture-password\r"
expect eof
set wait_result [wait]
exit [lindex $wait_result 3]
EXPECT
  [[ -f "$OUTPUT" && ! -L "$OUTPUT" ]]
  if stat -c '%a' "$OUTPUT" >/dev/null 2>&1; then MODE=$(stat -c '%a' "$OUTPUT"); else MODE=$(stat -f '%Lp' "$OUTPUT"); fi
  [[ "$MODE" == 600 ]]
  grep -Fqx 'ssid=\sfixture-network \\ primary\s' "$OUTPUT"
  grep -Fqx 'key-mgmt=wpa-psk' "$OUTPUT"
  grep -Fqx 'psk=fixture-password' "$OUTPUT"
  grep -Fqx 'psk-flags=0' "$OUTPUT"
fi

printf 'Wi-Fi keyfile helper contract tests: PASS\n'
