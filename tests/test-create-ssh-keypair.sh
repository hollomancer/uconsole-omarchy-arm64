#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
HELPER="$REPO_ROOT/scripts/create-ssh-keypair.sh"

bash -n "$HELPER"
HELP_OUTPUT=$($HELPER --help)
grep -Fq 'dedicated Ed25519 keypair with 64 KDF rounds' <<< "$HELP_OUTPUT"
grep -Fq 'an empty passphrase is' <<< "$HELP_OUTPUT"
grep -Fq 'passphrase option or non-interactive mode is accepted' <<< "$HELP_OUTPUT"
grep -Fq 'output directory must deny group/other writes' <<< "$HELP_OUTPUT"

for forbidden in --passphrase --password --password-file --stdin --non-interactive -N; do
  if "$HELPER" "$forbidden" >/dev/null 2>&1; then
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  else
    status=$?
    [[ $status -eq 2 ]] || { printf 'Expected %s to exit 2; observed %s\n' "$forbidden" "$status" >&2; exit 1; }
  fi
done
if "$HELPER" --output-private-key "$REPO_ROOT/id_uconsole" >/dev/null 2>&1; then
  printf 'Expected repository output to be rejected\n' >&2
  exit 1
else
  status=$?
  [[ $status -eq 2 ]]
fi
[[ ! -e "$REPO_ROOT/id_uconsole" && ! -e "$REPO_ROOT/id_uconsole.pub" ]]

grep -Fq 'set +x' "$HELPER"
grep -Fq 'ssh-keygen -q -t ed25519 -a 64 -C uconsole-admin -f "$STAGING_PRIVATE"' "$HELPER"
grep -Fq "ssh-keygen -y -P '' -f \"\$STAGING_PRIVATE\"" "$HELPER"
grep -Fq 'ln "$STAGING_PRIVATE" "$PRIVATE_KEY"' "$HELPER"
grep -Fq 'ln "$STAGING_PUBLIC" "$PUBLIC_KEY"' "$HELPER"
grep -Fq 'if [[ $PRIVATE_PUBLISHED -eq 1 ]]; then rm -f -- "$PRIVATE_KEY" || status=1; fi' "$HELPER"
! grep -Eq 'ssh-keygen .*-(N|P) .*[$](PASS|PASSWORD|SECRET)' "$HELPER"

if command -v expect >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
  TEST_BASE=${TMPDIR:-/tmp}
  TEST_BASE=${TEST_BASE%/}
  TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-ssh-helper-test.XXXXXX")
  cleanup() {
    case "$TEST_TMP" in
      /tmp/uconsole-ssh-helper-test.*|/private/tmp/uconsole-ssh-helper-test.*|/var/folders/*/T/uconsole-ssh-helper-test.*|/private/var/folders/*/T/uconsole-ssh-helper-test.*) rm -rf -- "$TEST_TMP" ;;
      *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
    esac
  }
  trap cleanup EXIT
  PRIVATE_KEY="$TEST_TMP/id_uconsole"
  HELPER="$HELPER" PRIVATE_KEY="$PRIVATE_KEY" expect <<'EXPECT'
log_user 0
set timeout 15
spawn $env(HELPER) --output-private-key $env(PRIVATE_KEY)
expect "Enter passphrase (empty for no passphrase):"
send -- "fixture-key-passphrase\r"
expect "Enter same passphrase again:"
send -- "fixture-key-passphrase\r"
expect eof
set wait_result [wait]
exit [lindex $wait_result 3]
EXPECT
  [[ -f "$PRIVATE_KEY" && ! -L "$PRIVATE_KEY" && -f "${PRIVATE_KEY}.pub" && ! -L "${PRIVATE_KEY}.pub" ]]
  if stat -c '%a' "$PRIVATE_KEY" >/dev/null 2>&1; then
    PRIVATE_MODE=$(stat -c '%a' "$PRIVATE_KEY")
    PUBLIC_MODE=$(stat -c '%a' "${PRIVATE_KEY}.pub")
  else
    PRIVATE_MODE=$(stat -f '%Lp' "$PRIVATE_KEY")
    PUBLIC_MODE=$(stat -f '%Lp' "${PRIVATE_KEY}.pub")
  fi
  [[ "$PRIVATE_MODE" == 600 && "$PUBLIC_MODE" == 644 ]]
  grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+ uconsole-admin$' "${PRIVATE_KEY}.pub"
  ssh-keygen -lf "${PRIVATE_KEY}.pub" -E sha256 >/dev/null
  if ssh-keygen -y -P '' -f "$PRIVATE_KEY" >/dev/null 2>&1; then
    printf 'Expected generated private key to reject an empty passphrase\n' >&2
    exit 1
  fi

  EMPTY_PRIVATE_KEY="$TEST_TMP/id_uconsole_empty"
  HELPER="$HELPER" PRIVATE_KEY="$EMPTY_PRIVATE_KEY" expect <<'EXPECT'
log_user 0
set timeout 15
spawn $env(HELPER) --output-private-key $env(PRIVATE_KEY)
expect "Enter passphrase (empty for no passphrase):"
send -- "\r"
expect "Enter same passphrase again:"
send -- "\r"
expect eof
set wait_result [wait]
if {[lindex $wait_result 3] != 2} { exit 1 }
exit 0
EXPECT
  [[ ! -e "$EMPTY_PRIVATE_KEY" && ! -e "${EMPTY_PRIVATE_KEY}.pub" ]]
fi

printf 'SSH keypair helper contract tests: PASS\n'
