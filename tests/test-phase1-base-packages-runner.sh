#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/install-phase1-base-packages.sh"
INSIDE="$REPO_ROOT/research/container/install-phase1-base-packages-inside.sh"
INSPECTOR="$REPO_ROOT/research/inspect-phase1-operator-root.sh"
INSPECTOR_INSIDE="$REPO_ROOT/research/container/inspect-phase1-operator-root-inside.sh"

bash -n "$RUNNER" "$INSIDE" "$INSPECTOR" "$INSPECTOR_INSIDE"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'operator-pending'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'must not be imaged or written to media'

for forbidden in --admin-user --ssh-public-key --console-password-hash-file --wifi-keyfile --password --secret --device --write-device --publish --build-image; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected %s to be rejected\n' "$forbidden" >&2; exit 1; }
done

"$RUNNER" --volume uconsole-unsafe >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected unsafe volume namespace to be rejected\n' >&2; exit 1; }

grep -Fq -- '--network none' "$RUNNER"
grep -Fq -- '--read-only --log-driver none' "$RUNNER"
grep -Fq -- '--mount "type=volume,src=$VOLUME,dst=/output"' "$RUNNER"
grep -Fq '/repo/scripts/install-base-system-packages.sh --plan' "$INSIDE"
[[ $(grep -Fc '/repo/scripts/install-base-system-packages.sh --apply' "$INSIDE") -eq 2 ]]
grep -Fq 'base-system-selection' "$INSIDE"
grep -Fq 'do not image or boot this root' "$INSIDE"

INSPECT_HELP=$($INSPECTOR --help)
printf '%s\n' "$INSPECT_HELP" | grep -Fq 'mounted read-only'
for forbidden in --apply --configure --build-image --device --write-device --publish; do
  "$INSPECTOR" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected inspector %s to be rejected\n' "$forbidden" >&2; exit 1; }
done
grep -Fq -- 'dst=/source,readonly' "$INSPECTOR"
grep -Fq -- '--read-only --log-driver none' "$INSPECTOR"
grep -Fq 'base-system-selection' "$INSPECTOR_INSIDE"
grep -Fq 'configure private identity/access before imaging or booting' "$INSPECTOR_INSIDE"

printf 'Phase 1 operator-pending base package runner contract tests: PASS\n'
