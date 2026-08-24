#!/usr/bin/env bash

# Explicitly exercise regular-file, loop-device and read-only-mount behavior on
# a candidate image output. Cleanup removes only the fixed probe created here.

set -u
set -o pipefail

PROBE_FILE=/output/.uconsole-omarchy-output-probe.img
PROBE_BYTES=67108864
LOOP_DEVICE=''
MOUNT_ROOT=''
MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local cleanup_status=$?
  trap - EXIT INT TERM
  if [[ $MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT" || cleanup_status=1; fi
  if [[ -n "$LOOP_DEVICE" ]]; then losetup -d "$LOOP_DEVICE" || cleanup_status=1; fi
  if [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]]; then rmdir "$MOUNT_ROOT" || cleanup_status=1; fi
  if [[ -f "$PROBE_FILE" ]]; then rm -f -- "$PROBE_FILE" || cleanup_status=1; fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output must be empty before the probe'
truncate -s "$PROBE_BYTES" "$PROBE_FILE" || fail 'unable to create the fixed probe file'
[[ -f "$PROBE_FILE" && ! -L "$PROBE_FILE" && $(stat -c '%s' "$PROBE_FILE") -eq $PROBE_BYTES ]] || fail 'probe file identity differs'
LOOP_DEVICE=$(losetup --find --show "$PROBE_FILE") || fail 'candidate output does not support a loop device'
mkfs.ext4 -F -L uconsole-probe "$LOOP_DEVICE" >/dev/null || fail 'candidate output loop device is not writable'
e2fsck -fn "$LOOP_DEVICE" || fail 'probe filesystem check failed'
MOUNT_ROOT=$(mktemp -d /tmp/uconsole-output-probe.XXXXXX) || fail 'unable to create the probe mountpoint'
mount -o ro "$LOOP_DEVICE" "$MOUNT_ROOT" || fail 'probe filesystem cannot be mounted read-only'
MOUNTED=1
[[ $(findmnt -n -o OPTIONS "$MOUNT_ROOT" | tr ',' '\n' | grep -Fxc ro) -eq 1 ]] || fail 'probe filesystem is not read-only'
[[ $(blkid -s LABEL -o value "$LOOP_DEVICE") == uconsole-probe ]] || fail 'probe filesystem label differs'
printf '[PASS] 64 MiB output loop-device probe mounted and checked read-only\n'
