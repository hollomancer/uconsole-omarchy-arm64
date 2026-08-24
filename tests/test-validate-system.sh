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

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-validator-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-validator-test.*|/private/tmp/uconsole-validator-test.*|/var/folders/*/T/uconsole-validator-test.*|/private/var/folders/*/T/uconsole-validator-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

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
for required_pass in hardware-selection uconsole-modules wayland-input hyprland-portal; do
  if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq "[PASS] $required_pass"; then
    printf 'PASS fixture did not report %s PASS\n' "$required_pass" >&2
    exit 1
  fi
done

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

STRICT_FIXTURE="$TEST_TMP/strict-fail"
cp -R "$PASS_FIXTURE" "$STRICT_FIXTURE"
rm "$STRICT_FIXTURE/commands/glxinfo.stdout" "$STRICT_FIXTURE/commands/hypr_devices.stdout"
printf 'Monitor DSI-1: 720x1280 transform: 0\n' > "$STRICT_FIXTURE/commands/hypr_monitors.stdout"
printf 'inactive\n' > "$STRICT_FIXTURE/commands/portal_status.stdout"
STRICT_OUTPUT=""
STRICT_STATUS=0
STRICT_OUTPUT=$("$VALIDATOR" --phase hyprland --fixture "$STRICT_FIXTURE" --packages-file "$PACKAGES" 2>&1)
STRICT_STATUS=$?
[[ $STRICT_STATUS -eq 1 ]] || { printf '%s\nExpected strict Hyprland fixture to fail\n' "$STRICT_OUTPUT" >&2; exit 1; }
for required_fail in opengl-acceleration display-orientation wayland-input hyprland-portal; do
  if ! printf '%s\n' "$STRICT_OUTPUT" | grep -Fq "[FAIL] $required_fail"; then
    printf '%s\nStrict fixture did not report %s FAIL\n' "$STRICT_OUTPUT" "$required_fail" >&2
    exit 1
  fi
done

printf 'validate-system fixtures: PASS\n'
