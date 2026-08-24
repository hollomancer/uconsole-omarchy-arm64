#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/configure-phase1-operator-root.sh"
INSIDE="$REPO_ROOT/research/container/configure-phase1-operator-root-inside.sh"
INSPECTOR="$REPO_ROOT/research/inspect-phase1-configured-root.sh"
INSPECTOR_INSIDE="$REPO_ROOT/research/container/inspect-phase1-configured-root-inside.sh"
INTEGRATION_RUNNER="$REPO_ROOT/research/test-phase1-configured-inspector.sh"
INTEGRATION_INSIDE="$REPO_ROOT/research/container/test-phase1-configured-inspector-inside.sh"

bash -n "$RUNNER" "$INSIDE" "$INSPECTOR" "$INSPECTOR_INSIDE" "$INTEGRATION_RUNNER" "$INTEGRATION_INSIDE"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'mounted read-only'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--confirm-volume'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'Never pass a plaintext password'

for forbidden in --password --password-hash --wifi-password --wifi-psk --private-key --device --write-device --build-image --publish; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected runner %s to be rejected\n' "$forbidden" >&2; exit 1; }
done
for forbidden in --apply --configure --build --build-image --device --write-device --publish; do
  "$INSPECTOR" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected inspector %s to be rejected\n' "$forbidden" >&2; exit 1; }
done

grep -Fq 'VOLUME_MOUNT="$VOLUME_MOUNT,readonly"' "$RUNNER"
grep -Fq -- '--network none' "$RUNNER"
grep -Fq -- '--read-only --log-driver none' "$RUNNER"
grep -Fq 'CONSOLE_PASSWORD_HASH_FILE" in "$REPO_ROOT"' "$RUNNER"
grep -Fq '/repo/scripts/configure-base-system.sh --plan' "$INSIDE"
[[ $(grep -Fc '/repo/scripts/configure-base-system.sh --apply' "$INSIDE") -eq 2 ]]
grep -Fq 'inspect-phase1-configured-root.sh' "$RUNNER"

INSPECT_HELP=$($INSPECTOR --help)
printf '%s\n' "$INSPECT_HELP" | grep -Fq 'mounted read-only'
grep -Fq 'dst=/source,readonly' "$INSPECTOR"
grep -Fq -- '--privileged' "$INSPECTOR"
grep -Fq -- '--tmpfs /source/root/run' "$INSPECTOR"
grep -Fq '/repo/scripts/build-image.sh --plan' "$INSPECTOR_INSIDE"
! grep -Fq '/repo/scripts/build-image.sh --build' "$INSPECTOR_INSIDE"
grep -Fq 'no persistent SSH host key and no image created' "$INSPECTOR_INSIDE"
grep -Fq 'mount --rbind /dev "$ROOT/dev"' "$INSPECTOR_INSIDE"
grep -Fq 'umount -R "$ROOT/dev"' "$INSPECTOR_INSIDE"

INTEGRATION_HELP=$($INTEGRATION_RUNNER --help)
printf '%s\n' "$INTEGRATION_HELP" | grep -Fq 'removed afterward'
for forbidden in --retain-workspace --remove-archive --delete-source --publish --device; do
  "$INTEGRATION_RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected integration runner %s to be rejected\n' "$forbidden" >&2; exit 1; }
done
grep -Fq 'dst=/archive,readonly' "$INTEGRATION_RUNNER"
grep -Fq 'dst=/work' "$INTEGRATION_RUNNER"
grep -Fq 'uconsole-phase1-configured-inspection-20260824)' "$INTEGRATION_RUNNER"
! grep -Fq 'rm -rf -- "$ARCHIVE_DIRECTORY"' "$INTEGRATION_RUNNER"
grep -Fq 'blockdev --setro "$LOOP_DEVICE"' "$INTEGRATION_INSIDE"
grep -Fq 'blockdev --setrw "$LOOP_DEVICE"' "$INTEGRATION_INSIDE"
grep -Fq 'mount -o remount,ro "$RESTORE_MOUNT"' "$INTEGRATION_INSIDE"
grep -Fq 'findmnt -rn -M "$RESTORE_MOUNT"' "$INTEGRATION_INSIDE"
grep -Fq 'UCONSOLE_INSPECTION_ROOT="$RESTORE_MOUNT/root"' "$INTEGRATION_INSIDE"

printf 'Phase 1 operator configuration runner contract tests: PASS\n'
