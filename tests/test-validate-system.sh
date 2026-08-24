#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=""
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

VALIDATOR="$REPO_ROOT/scripts/validate-system.sh"
PACKAGES="$REPO_ROOT/config/arm64-overrides/omarchy-core.packages"
PASS_FIXTURE="$TEST_DIR/fixtures/validate-pass"
FAIL_FIXTURE="$TEST_DIR/fixtures/validate-fail"

PASS_OUTPUT=""
if ! PASS_OUTPUT=$("$VALIDATOR" --phase omarchy --fixture "$PASS_FIXTURE" --packages-file "$PACKAGES"); then
  printf '%s\n' "$PASS_OUTPUT" >&2
  printf 'Expected complete fixture to pass\n' >&2
  exit 1
fi
if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq '[PASS] architecture'; then
  printf 'PASS fixture did not report architecture PASS\n' >&2
  exit 1
fi
if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq 'FAIL=0'; then
  printf 'PASS fixture reported a failure\n' >&2
  exit 1
fi

FAIL_OUTPUT=""
FAIL_STATUS=0
FAIL_OUTPUT=$("$VALIDATOR" --phase hardware --fixture "$FAIL_FIXTURE" --packages-file "$PACKAGES" 2>&1)
FAIL_STATUS=$?
if [[ $FAIL_STATUS -ne 1 ]]; then
  printf '%s\n' "$FAIL_OUTPUT" >&2
  printf 'Expected failing fixture to exit 1; got %d\n' "$FAIL_STATUS" >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] architecture'; then
  printf 'Failing fixture did not report architecture FAIL\n' >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] opengl-acceleration'; then
  printf 'Failing fixture did not reject llvmpipe\n' >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] vulkan-acceleration'; then
  printf 'Failing fixture did not reject software Vulkan\n' >&2
  exit 1
fi

printf 'validate-system fixtures: PASS\n'

