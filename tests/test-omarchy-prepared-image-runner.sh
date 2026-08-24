#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/test-omarchy-prepared-image.sh"
INSIDE="$REPO_ROOT/research/container/test-omarchy-prepared-image-inside.sh"
PROBE_INSIDE="$REPO_ROOT/research/container/probe-image-output-inside.sh"

bash -n "$RUNNER" "$INSIDE" "$PROBE_INSIDE"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--build-synthetic-image'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--output-directory'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--probe-output'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'must never be written to media or published'

for forbidden in --device --write-device --apply-in-place --publish; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || {
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  }
done

"$RUNNER" --source-volume unsafe --output-volume unsafe --build-synthetic-image >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected unsafe volume names to be rejected\n' >&2; exit 1; }

"$RUNNER" --source-volume uconsole-safe --check >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected a missing output target to be rejected\n' >&2; exit 1; }

"$RUNNER" --source-volume uconsole-safe \
  --output-volume uconsole-omarchy-prepared-image-safe \
  --output-directory /Volumes/External/uconsole-omarchy-prepared-image-safe \
  --check >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected multiple output targets to be rejected\n' >&2; exit 1; }

"$RUNNER" --check --probe-output >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected multiple actions to be rejected\n' >&2; exit 1; }

grep -Fq -- '--mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly"' "$RUNNER"
grep -Fq 'OUTPUT_MOUNT_RO="type=volume,src=$OUTPUT_VOLUME,dst=/output,readonly"' "$RUNNER"
grep -Fq 'OUTPUT_MOUNT_RO="type=bind,src=$OUTPUT_DIRECTORY,dst=/output,readonly"' "$RUNNER"
grep -Fq '^/Volumes/' "$RUNNER"
grep -Fq -- '--require-omarchy-prepared' "$INSIDE"
grep -Fq -- '--size-mib 8192' "$INSIDE"
grep -Fq 'MIN_FREE_KIB=6291456' "$RUNNER"
grep -Fq 'MIN_FREE_KIB=6291456' "$INSIDE"
grep -Fq "'[FAIL] output free space" "$RUNNER"
grep -Fq 'PROBE_FILE=/output/.uconsole-omarchy-output-probe.img' "$PROBE_INSIDE"
grep -Fq 'rm -f -- "$PROBE_FILE"' "$PROBE_INSIDE"
grep -Fq 'mount -o ro "$LOOP_DEVICE"' "$PROBE_INSIDE"
grep -Fq "'session_activated=no'" "$INSIDE"
grep -Fq "'activation=no'" "$INSIDE"
grep -Fq 'mount -o ro "$ROOT_LOOP_DEVICE"' "$INSIDE"

printf 'prepared Omarchy image runner contract tests: PASS\n'
