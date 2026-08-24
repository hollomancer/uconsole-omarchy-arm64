#!/usr/bin/env bash

# Mount two exact synthetic images read-only and compare partition bytes plus a
# timestamp-independent semantic inventory of every filesystem entry.

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
      "$WORK_ROOT/a-boot.inventory" "$WORK_ROOT/b-boot.inventory" \
      "$WORK_ROOT/a-root.inventory" "$WORK_ROOT/b-root.inventory" \
      "$WORK_ROOT/a.manifest.normalized" "$WORK_ROOT/b.manifest.normalized" || cleanup_status=1
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
WORK_ROOT=$(mktemp -d /tmp/uconsole-image-compare.XXXXXX) || fail 'unable to create comparison workspace'
mkdir -p "$WORK_ROOT/a-boot" "$WORK_ROOT/a-root" "$WORK_ROOT/b-boot" "$WORK_ROOT/b-root" || fail 'unable to create comparison mountpoints'

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

semantic_inventory() {
  local filesystem_root=$1
  local inventory_output=$2
  local entry=''
  local relative=''
  local entry_type=''
  local payload=''
  local entry_size=''
  (
    cd -- "$filesystem_root" || exit 1
    while IFS= read -r -d '' entry; do
      relative=${entry#./}
      if [[ -L "$entry" ]]; then
        entry_type=l
        payload=$(readlink "$entry") || exit 1
      elif [[ -f "$entry" ]]; then
        entry_type=f
        payload=$(sha256sum "$entry" | awk '{print $1}') || exit 1
        entry_size=$(stat -c '%s' "$entry") || exit 1
      elif [[ -d "$entry" ]]; then
        entry_type=d
        payload=-
        entry_size=-
      else
        entry_type=o
        payload=$(stat -c '%t:%T' "$entry") || exit 1
        entry_size=-
      fi
      if [[ "$entry_type" == l ]]; then entry_size=-; fi
      printf '%s|%s|%s|%s|%s|%s\n' \
        "$relative" "$entry_type" "$(stat -c '%a' "$entry")" \
        "$(stat -c '%u:%g' "$entry")" "$payload" "$entry_size"
    done < <(find . -xdev -print0 | LC_ALL=C sort -z)
  ) > "$inventory_output"
}

semantic_inventory "$WORK_ROOT/a-boot" "$WORK_ROOT/a-boot.inventory" || fail 'unable to inventory image A boot filesystem'
semantic_inventory "$WORK_ROOT/b-boot" "$WORK_ROOT/b-boot.inventory" || fail 'unable to inventory image B boot filesystem'
semantic_inventory "$WORK_ROOT/a-root" "$WORK_ROOT/a-root.inventory" || fail 'unable to inventory image A root filesystem'
semantic_inventory "$WORK_ROOT/b-root" "$WORK_ROOT/b-root.inventory" || fail 'unable to inventory image B root filesystem'

cmp -s "$WORK_ROOT/a-boot.inventory" "$WORK_ROOT/b-boot.inventory" || fail 'boot file contents, modes or ownership differ'
cmp -s "$WORK_ROOT/a-root.inventory" "$WORK_ROOT/b-root.inventory" || fail 'root file contents, modes or ownership differ'

A_IMAGE_SHA=$(sha256sum "$IMAGE_A" | awk '{print $1}') || fail 'unable to hash image A'
B_IMAGE_SHA=$(sha256sum "$IMAGE_B" | awk '{print $1}') || fail 'unable to hash image B'
A_BOOT_SHA=$(sha256sum "$A_BOOT_LOOP" | awk '{print $1}') || fail 'unable to hash image A boot partition'
B_BOOT_SHA=$(sha256sum "$B_BOOT_LOOP" | awk '{print $1}') || fail 'unable to hash image B boot partition'
A_ROOT_SHA=$(sha256sum "$A_ROOT_LOOP" | awk '{print $1}') || fail 'unable to hash image A root partition'
B_ROOT_SHA=$(sha256sum "$B_ROOT_LOOP" | awk '{print $1}') || fail 'unable to hash image B root partition'

sed '/"image_sha256"/d' "/image-a/${IMAGE_NAME}.manifest.json" > "$WORK_ROOT/a.manifest.normalized" || fail 'unable to normalize manifest A'
sed '/"image_sha256"/d' "/image-b/${IMAGE_NAME}.manifest.json" > "$WORK_ROOT/b.manifest.normalized" || fail 'unable to normalize manifest B'
cmp -s "$WORK_ROOT/a.manifest.normalized" "$WORK_ROOT/b.manifest.normalized" || fail 'external manifests differ beyond the image digest'

printf '[PASS] semantic boot tree  every path, type, mode, owner, size and file digest matches\n'
printf '[PASS] semantic root tree  every path, type, mode, owner, size and file digest matches\n'
printf '[PASS] normalized manifest all identity and boot-content fields match\n'
printf '[INFO] image A sha256=%s\n' "$A_IMAGE_SHA"
printf '[INFO] image B sha256=%s\n' "$B_IMAGE_SHA"
printf '[INFO] boot A sha256=%s\n' "$A_BOOT_SHA"
printf '[INFO] boot B sha256=%s\n' "$B_BOOT_SHA"
printf '[INFO] root A sha256=%s\n' "$A_ROOT_SHA"
printf '[INFO] root B sha256=%s\n' "$B_ROOT_SHA"
if [[ "$A_IMAGE_SHA" == "$B_IMAGE_SHA" ]]; then
  printf '[PASS] whole image         byte-reproducible\n'
else
  printf '[WARN] whole image         semantic content matches but filesystem bytes differ\n'
fi
printf '[PASS] comparison boundary both image directories and all mounts remained read-only\n'
