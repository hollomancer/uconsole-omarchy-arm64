#!/usr/bin/env bash

# Run the deterministic host-side contract suite. Hardware, Docker, network
# access and privileged mounts are not required by these tests.

set -u
set -o pipefail

TEST_DIR=""
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi

TOTAL=0
PASSED=0
SKIPPED=0
FAILED=0
TEST_OUTPUT=''

for TEST_FILE in "$TEST_DIR"/test-*.sh; do
  [[ -f "$TEST_FILE" ]] || continue
  TOTAL=$((TOTAL + 1))
  TEST_NAME=${TEST_FILE##*/}
  printf '[RUN ] %s\n' "$TEST_NAME"
  if TEST_OUTPUT=$(bash "$TEST_FILE" 2>&1); then
    printf '%s\n' "$TEST_OUTPUT"
    if printf '%s\n' "$TEST_OUTPUT" | grep -Fq ': SKIP ('; then
      SKIPPED=$((SKIPPED + 1))
      printf '[SKIP] %s\n' "$TEST_NAME"
    else
      PASSED=$((PASSED + 1))
      printf '[PASS] %s\n' "$TEST_NAME"
    fi
  else
    printf '%s\n' "$TEST_OUTPUT" >&2
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s\n' "$TEST_NAME" >&2
  fi
done

if [[ $TOTAL -eq 0 ]]; then
  printf 'No test-*.sh files found in %s\n' "$TEST_DIR" >&2
  exit 2
fi

printf '\nContract test summary: total=%d passed=%d skipped=%d failed=%d\n' "$TOTAL" "$PASSED" "$SKIPPED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
exit 0
