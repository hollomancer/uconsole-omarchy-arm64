#!/usr/bin/env bash

# Restore the private archive into a sparse ext4 file on external storage,
# remount it read-only, and run the production configured-root inspector.

set -u
set -o pipefail

IMAGE_FILE=/work/uconsole-phase1-configured-inspection.ext4
RESTORE_MOUNT=/restore
RESTORE_MOUNTED=0
RUN_MOUNTED=0
LOOP_DEVICE=''

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $RUN_MOUNTED -eq 1 ]]; then umount "$RESTORE_MOUNT/root/run" || status=1; fi
  if [[ $RESTORE_MOUNTED -eq 1 ]]; then umount "$RESTORE_MOUNT" || status=1; fi
  if [[ -n "$LOOP_DEVICE" ]] && losetup "$LOOP_DEVICE" >/dev/null 2>&1; then losetup -d "$LOOP_DEVICE" || status=1; fi
  exit "$status"
}
trap cleanup_mounts EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -d /work && -d /archive && -d "$RESTORE_MOUNT" ]] || fail 'required integration mount is missing'
[[ -z "$(find /work -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'external integration workspace must be empty'
truncate -s 4G "$IMAGE_FILE" || fail 'unable to allocate sparse ext4 image'
mkfs.ext4 -q -F -U 44444444-5555-4666-8777-888888888888 "$IMAGE_FILE" || fail 'unable to format ext4 integration image'
LOOP_DEVICE=$(losetup --find --show "$IMAGE_FILE") || fail 'unable to attach ext4 integration loop device'
blockdev --setrw "$LOOP_DEVICE" || fail 'unable to set fresh ext4 loop device writable for restore'
[[ $(blockdev --getro "$LOOP_DEVICE") == 0 ]] || fail 'fresh ext4 loop device remained read-only before restore'
mount -o rw "$LOOP_DEVICE" "$RESTORE_MOUNT" || fail 'unable to mount ext4 integration image writable'
RESTORE_MOUNTED=1
rm -rf -- "$RESTORE_MOUNT/lost+found" || fail 'unable to remove empty ext4 recovery directory'

UCONSOLE_ARCHIVE_ACTION=restore \
UCONSOLE_VOLUME_NAME=uconsole-base-system-integration-20260824 \
  /repo/research/container/archive-project-volume-inside.sh || fail 'verified private archive restore failed'

sync || fail 'unable to flush restored ext4 image'
mount -o remount,ro "$RESTORE_MOUNT" || fail 'unable to remount restored ext4 image read-only'
MOUNT_SOURCE=$(findmnt -rn -M "$RESTORE_MOUNT" -o SOURCE | tail -n 1) || fail 'unable to inspect restored ext4 mount source'
MOUNT_OPTIONS=$(findmnt -rn -M "$RESTORE_MOUNT" -o OPTIONS | tail -n 1) || fail 'unable to inspect restored ext4 mount options'
[[ "$MOUNT_SOURCE" == "$LOOP_DEVICE" ]] || fail "restored ext4 mount source differs: $MOUNT_SOURCE"
[[ ",$MOUNT_OPTIONS," == *,ro,* ]] || fail "restored ext4 filesystem is not mounted read-only: $MOUNT_OPTIONS"
blockdev --setro "$LOOP_DEVICE" || fail 'unable to set configured ext4 loop device read-only'
[[ $(blockdev --getro "$LOOP_DEVICE") == 1 ]] || fail 'configured ext4 loop device did not become read-only'
mount -t tmpfs -o rw,nosuid,nodev tmpfs "$RESTORE_MOUNT/root/run" || fail 'unable to add transient inspection /run'
RUN_MOUNTED=1

UCONSOLE_INSPECTION_ROOT="$RESTORE_MOUNT/root" \
  /repo/research/container/inspect-phase1-configured-root-inside.sh || fail 'configured-root inspection failed'

printf '[PASS] configured archive restored with Linux ownership, ACL and xattr semantics\n'
printf '[PASS] sparse ext4 source was read-only throughout production inspection\n'
