#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/build-phase1-image.sh"
INSIDE="$REPO_ROOT/research/container/build-phase1-image-inside.sh"
CONFIG_INSPECTOR="$REPO_ROOT/research/container/inspect-phase1-configured-root-inside.sh"

bash -n "$RUNNER" "$INSIDE" "$CONFIG_INSPECTOR"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--build-image'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--inspect-image'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--confirm-source-volume'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--identity-file'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'Hyprland and Omarchy state are forbidden'

for forbidden in --device --write-device --publish --require-omarchy-prepared; do
  if "$RUNNER" "$forbidden" >/dev/null 2>&1; then
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  else
    status=$?
    [[ $status -eq 2 ]] || { printf 'Expected %s to exit 2; observed %s\n' "$forbidden" "$status" >&2; exit 1; }
  fi
done

if "$RUNNER" --identity-file "$REPO_ROOT/config/image/phase1-candidate.env" --disk-id a1b2c3d4 >/dev/null 2>&1; then
  printf 'Expected mixed identity inputs to be rejected\n' >&2
  exit 1
else
  status=$?
  [[ $status -eq 2 ]] || { printf 'Expected mixed identity inputs to exit 2; observed %s\n' "$status" >&2; exit 1; }
fi

grep -Fq 'dst=/source,readonly' "$RUNNER"
grep -Fq '^/Volumes/' "$RUNNER"
grep -Fq -- '--network none --log-driver none' "$RUNNER"
grep -Fq 'VOLUME_MOUNT' "$RUNNER" >/dev/null 2>&1 && { printf 'Unexpected broad output-volume path\n' >&2; exit 1; }
grep -Fq '/repo/scripts/build-image.sh --plan' "$INSIDE"
grep -Fq '/repo/scripts/build-image.sh --build' "$INSIDE"
grep -Fq 'desktop state is forbidden in Phase 1' "$INSIDE"
grep -Fq 'losetup --find --show --read-only' "$INSIDE"
grep -Fq 'UCONSOLE_INSPECTION_ROOT="$MOUNT_ROOT"' "$INSIDE"
grep -Fq 'no physical device was opened' "$INSIDE"
grep -Fq 'phase1-image-inspect' "$CONFIG_INSPECTOR"

printf 'Phase 1 external image runner contract tests: PASS\n'
