#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/compare-omarchy-prepared-images.sh"
INSIDE="$REPO_ROOT/research/container/compare-omarchy-prepared-images-inside.sh"

bash -n "$RUNNER" "$INSIDE"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'Both directories are mounted read-only'

for forbidden in --device --write-device --delete --publish; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected %s to be rejected\n' "$forbidden" >&2; exit 1; }
done

"$RUNNER" --image-a-dir unsafe --image-b-dir unsafe >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected unsafe directories to be rejected\n' >&2; exit 1; }

grep -Fq 'dst=/image-a,readonly' "$RUNNER"
grep -Fq 'dst=/image-b,readonly' "$RUNNER"
grep -Fq -- '--read-only' "$INSIDE"
grep -Fq 'mount -o ro' "$INSIDE"
grep -Fq 'semantic_inventory' "$INSIDE"
grep -Fq 'filesystem bytes differ' "$INSIDE"

printf 'prepared image comparison contract tests: PASS\n'
