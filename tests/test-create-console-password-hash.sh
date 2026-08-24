#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
HELPER="$REPO_ROOT/scripts/create-console-password-hash.sh"

bash -n "$HELPER"
HELP_OUTPUT=$($HELPER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'mode-0600 SHA-512 crypt file'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'never an argument, file, log message or image layer'

for forbidden in --password --password-file --hash --stdin --non-interactive; do
  "$HELPER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected %s to be rejected\n' "$forbidden" >&2; exit 1; }
done
"$HELPER" --output "$REPO_ROOT/private.hash" >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected repository output to be rejected\n' >&2; exit 1; }
[[ ! -e "$REPO_ROOT/private.hash" ]] || { printf 'Rejected repository output was created\n' >&2; exit 1; }

grep -Fq 'read -r -s FIRST_PASSWORD </dev/tty' "$HELPER"
grep -Fq 'read -r -s SECOND_PASSWORD </dev/tty' "$HELPER"
grep -Fq 'set +x' "$HELPER"
grep -Fq -- '--network none' "$HELPER"
grep -Fq -- '--read-only --log-driver none' "$HELPER"
grep -Fq 'openssl passwd -6 -stdin' "$HELPER"
! grep -Eq 'docker .*FIRST_PASSWORD|openssl .*FIRST_PASSWORD' "$HELPER"
grep -Fq 'set -o noclobber' "$HELPER"

printf 'console password hash helper contract tests: PASS\n'
