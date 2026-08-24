#!/usr/bin/env bash

# Diagnose byte variance between two semantically equal images. All image and
# filesystem access is read-only; temporary reports live in the container.

set -u
set -o pipefail

IMAGE_NAME=uconsole-omarchy-prepared-integration.img
IMAGE_A=/image-a/$IMAGE_NAME
IMAGE_B=/image-b/$IMAGE_NAME
BOOT_OFFSET=4194304
BOOT_SIZE_BYTES=536870912
ROOT_OFFSET=541065216
ROOT_SIZE_BYTES=8047820800
WORK_ROOT=''
A_BOOT_LOOP=''
A_ROOT_LOOP=''
B_BOOT_LOOP=''
B_ROOT_LOOP=''
MOUNTED_PATHS=()

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local cleanup_status=$?
  local mounted_path=''
  local loop_device=''
  trap - EXIT INT TERM
  for ((index=${#MOUNTED_PATHS[@]} - 1; index >= 0; index--)); do
    mounted_path=${MOUNTED_PATHS[$index]}
    umount "$mounted_path" || cleanup_status=1
  done
  for loop_device in "$A_BOOT_LOOP" "$A_ROOT_LOOP" "$B_BOOT_LOOP" "$B_ROOT_LOOP"; do
    if [[ -n "$loop_device" ]]; then losetup -d "$loop_device" || cleanup_status=1; fi
  done
  if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
    rm -f -- \
      "$WORK_ROOT/a-boot.times" "$WORK_ROOT/b-boot.times" \
      "$WORK_ROOT/a-root.times" "$WORK_ROOT/b-root.times" \
      "$WORK_ROOT/a-root.super" "$WORK_ROOT/b-root.super" \
      "$WORK_ROOT/a-root.summary" "$WORK_ROOT/b-root.summary" || cleanup_status=1
    for mounted_path in "$WORK_ROOT/a-boot" "$WORK_ROOT/a-root" "$WORK_ROOT/b-boot" "$WORK_ROOT/b-root"; do
      if [[ -d "$mounted_path" ]]; then rmdir "$mounted_path" || cleanup_status=1; fi
    done
    rmdir "$WORK_ROOT" || cleanup_status=1
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for image_path in "$IMAGE_A" "$IMAGE_B"; do
  [[ -f "$image_path" && ! -b "$image_path" && $(stat -c '%s' "$image_path") -eq 8589934592 ]] || fail "image identity differs: $image_path"
done
WORK_ROOT=$(mktemp -d /tmp/uconsole-image-metadata.XXXXXX) || fail 'unable to create metadata workspace'
mkdir -p "$WORK_ROOT/a-boot" "$WORK_ROOT/a-root" "$WORK_ROOT/b-boot" "$WORK_ROOT/b-root" || fail 'unable to create metadata mountpoints'

A_BOOT_LOOP=$(losetup --find --show --read-only --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$IMAGE_A") || fail 'unable to attach image A boot range'
A_ROOT_LOOP=$(losetup --find --show --read-only --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$IMAGE_A") || fail 'unable to attach image A root range'
B_BOOT_LOOP=$(losetup --find --show --read-only --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$IMAGE_B") || fail 'unable to attach image B boot range'
B_ROOT_LOOP=$(losetup --find --show --read-only --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$IMAGE_B") || fail 'unable to attach image B root range'

for mount_pair in \
  "$A_BOOT_LOOP:$WORK_ROOT/a-boot" \
  "$A_ROOT_LOOP:$WORK_ROOT/a-root" \
  "$B_BOOT_LOOP:$WORK_ROOT/b-boot" \
  "$B_ROOT_LOOP:$WORK_ROOT/b-root"; do
  loop_device=${mount_pair%%:*}
  mounted_path=${mount_pair#*:}
  mount -o ro "$loop_device" "$mounted_path" || fail "unable to mount read-only: $mounted_path"
  MOUNTED_PATHS+=("$mounted_path")
done

timestamp_inventory() {
  local filesystem_root=$1
  local output=$2
  (
    cd -- "$filesystem_root" || exit 1
    find . -xdev -mindepth 1 -printf '%P\t%T@\t%C@\n' | LC_ALL=C sort
  ) > "$output"
}

timestamp_counts() {
  local a_inventory=$1
  local b_inventory=$2
  local label=$3
  local counts=''
  counts=$(paste "$a_inventory" "$b_inventory" | awk -F '\t' '
    $1 != $4 { path_mismatch++ }
    $2 != $5 { mtime_differences++ }
    $3 != $6 { ctime_differences++ }
    END { printf "entries=%d path_mismatches=%d mtime_differences=%d ctime_differences=%d", NR, path_mismatch, mtime_differences, ctime_differences }
  ') || fail "unable to compare $label timestamps"
  printf '[INFO] %s timestamps %s\n' "$label" "$counts"
}

timestamp_inventory "$WORK_ROOT/a-boot" "$WORK_ROOT/a-boot.times" || fail 'unable to inventory image A boot timestamps'
timestamp_inventory "$WORK_ROOT/b-boot" "$WORK_ROOT/b-boot.times" || fail 'unable to inventory image B boot timestamps'
timestamp_inventory "$WORK_ROOT/a-root" "$WORK_ROOT/a-root.times" || fail 'unable to inventory image A root timestamps'
timestamp_inventory "$WORK_ROOT/b-root" "$WORK_ROOT/b-root.times" || fail 'unable to inventory image B root timestamps'
timestamp_counts "$WORK_ROOT/a-boot.times" "$WORK_ROOT/b-boot.times" boot
timestamp_counts "$WORK_ROOT/a-root.times" "$WORK_ROOT/b-root.times" root

if ! dumpe2fs -h "$A_ROOT_LOOP" > "$WORK_ROOT/a-root.super" 2>&1; then fail 'unable to read image A ext4 superblock'; fi
if ! dumpe2fs -h "$B_ROOT_LOOP" > "$WORK_ROOT/b-root.super" 2>&1; then fail 'unable to read image B ext4 superblock'; fi
SUPER_FIELDS='Filesystem UUID|Filesystem features|Filesystem state|Inode count|Block count|Reserved block count|Free blocks|Free inodes|Block size|Blocks per group|Inodes per group|Filesystem created|Last mount time|Last write time|Mount count|Last checked|Lifetime writes|Directory Hash Seed|Checksum'
grep -E "$SUPER_FIELDS" "$WORK_ROOT/a-root.super" > "$WORK_ROOT/a-root.summary" || fail 'image A ext4 summary lacks expected fields'
grep -E "$SUPER_FIELDS" "$WORK_ROOT/b-root.super" > "$WORK_ROOT/b-root.summary" || fail 'image B ext4 summary lacks expected fields'

A_BOOT_SECTOR_SHA=$(dd if="$A_BOOT_LOOP" bs=512 count=1 status=none | sha256sum | awk '{print $1}') || fail 'unable to hash image A FAT boot sector'
B_BOOT_SECTOR_SHA=$(dd if="$B_BOOT_LOOP" bs=512 count=1 status=none | sha256sum | awk '{print $1}') || fail 'unable to hash image B FAT boot sector'
A_EXT4_SUPER_SHA=$(dd if="$A_ROOT_LOOP" bs=512 skip=2 count=2 status=none | sha256sum | awk '{print $1}') || fail 'unable to hash image A ext4 superblock bytes'
B_EXT4_SUPER_SHA=$(dd if="$B_ROOT_LOOP" bs=512 skip=2 count=2 status=none | sha256sum | awk '{print $1}') || fail 'unable to hash image B ext4 superblock bytes'

printf '[INFO] FAT boot sector A sha256=%s\n' "$A_BOOT_SECTOR_SHA"
printf '[INFO] FAT boot sector B sha256=%s\n' "$B_BOOT_SECTOR_SHA"
printf '[INFO] ext4 superblock A sha256=%s\n' "$A_EXT4_SUPER_SHA"
printf '[INFO] ext4 superblock B sha256=%s\n' "$B_EXT4_SUPER_SHA"
printf '%s\n' '--- ext4 superblock field differences ---'
DIFF_STATUS=0
diff -u "$WORK_ROOT/a-root.summary" "$WORK_ROOT/b-root.summary" || DIFF_STATUS=$?
[[ $DIFF_STATUS -eq 0 || $DIFF_STATUS -eq 1 ]] || fail 'unable to compare ext4 superblock summaries'
printf '[PASS] diagnostic boundary both images and all filesystem mounts remained read-only\n'
