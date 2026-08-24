#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
PLANNER="$REPO_ROOT/scripts/plan-sd-write-macos.sh"

bash -n "$PLANNER"
HELP_OUTPUT=$($PLANNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'read-only macOS preflight'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'removable, external,'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'APFS targets are rejected'

for forbidden in --write --write-device --unmount --erase --format --i-understand-this-erases-the-device; do
  if "$PLANNER" "$forbidden" >/dev/null 2>&1; then
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  else
    status=$?
    [[ $status -eq 2 ]] || { printf 'Expected %s to exit 2; observed %s\n' "$forbidden" "$status" >&2; exit 1; }
  fi
done

grep -Fq '[[ "$WHOLE_DISK" == true ]]' "$PLANNER"
grep -Fq '[[ "$INTERNAL" == false ]]' "$PLANNER"
grep -Fq '[[ "$PHYSICAL" == Physical ]]' "$PLANNER"
grep -Fq '[[ "$REMOVABLE_MEDIA" == true ]]' "$PLANNER"
grep -Fq '[[ "$BLOCK_SIZE" == 512 ]]' "$PLANNER"
grep -Fq 'APFS target requires a separate synthesized-descendant audit' "$PLANNER"
grep -Fq 'target descendant is mounted' "$PLANNER"
grep -Fq 'No bytes were written and no mount state changed.' "$PLANNER"
! grep -Eq 'diskutil (unmount|erase|partition|zeroDisk)|(^|[[:space:]])dd([[:space:]]|$)' "$PLANNER"

printf 'macOS SD write-plan contract tests: PASS\n'
