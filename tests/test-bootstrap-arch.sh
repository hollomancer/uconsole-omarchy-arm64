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
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-arch.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-bootstrap-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-bootstrap-test.*|/private/tmp/uconsole-bootstrap-test.*|/var/folders/*/T/uconsole-bootstrap-test.*|/private/var/folders/*/T/uconsole-bootstrap-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

ROOTFS="$TEST_TMP/rootfs.tar.gz"
printf 'deterministic rootfs fixture\n' > "$ROOTFS"
if command -v sha256sum >/dev/null 2>&1; then
  DIGEST=$(sha256sum "$ROOTFS" | awk '{print $1}')
else
  DIGEST=$(shasum -a 256 "$ROOTFS" | awk '{print $1}')
fi

PLAN_OUTPUT=""
if ! PLAN_OUTPUT=$("$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 "$DIGEST" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected plan validation to pass\n' >&2
  exit 1
fi
if ! printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'No physical device was opened or written.'; then
  printf 'Plan did not state its device safety result\n' >&2
  exit 1
fi

BAD_STATUS=0
"$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 '0000000000000000000000000000000000000000000000000000000000000000' --plan >/dev/null 2>&1
BAD_STATUS=$?
if [[ $BAD_STATUS -ne 2 ]]; then
  printf 'Expected bad digest to exit 2; got %d\n' "$BAD_STATUS" >&2
  exit 1
fi

DEVICE_STATUS=0
"$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 "$DIGEST" --device /dev/disk99 >/dev/null 2>&1
DEVICE_STATUS=$?
if [[ $DEVICE_STATUS -ne 2 ]]; then
  printf 'Expected block-device option to be rejected; got %d\n' "$DEVICE_STATUS" >&2
  exit 1
fi

ACTION_STATUS=0
"$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 "$DIGEST" --plan --create-empty-image --image "$TEST_TMP/conflict.img" >/dev/null 2>&1
ACTION_STATUS=$?
if [[ $ACTION_STATUS -ne 2 ]]; then
  printf 'Expected conflicting actions to be rejected; got %d\n' "$ACTION_STATUS" >&2
  exit 1
fi

IMAGE="$TEST_TMP/development.img"
if ! "$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 "$DIGEST" --create-empty-image --image "$IMAGE" --size-mib 1024 >/dev/null; then
  printf 'Expected sparse image creation to pass\n' >&2
  exit 1
fi
if [[ ! -f "$IMAGE" ]]; then
  printf 'Sparse image was not created\n' >&2
  exit 1
fi

OVERWRITE_STATUS=0
"$BOOTSTRAP" --rootfs "$ROOTFS" --rootfs-sha256 "$DIGEST" --create-empty-image --image "$IMAGE" --size-mib 1024 >/dev/null 2>&1
OVERWRITE_STATUS=$?
if [[ $OVERWRITE_STATUS -ne 2 ]]; then
  printf 'Expected existing image refusal; got %d\n' "$OVERWRITE_STATUS" >&2
  exit 1
fi

printf 'bootstrap-arch safety tests: PASS\n'
