#!/usr/bin/env bash

# Production Phase 1 image plan/build/read-only inspection inside the pinned
# ARM64 container. Desktop state is deliberately forbidden.

set -u
set -o pipefail

ROOT_TREE=/source/root
OUTPUT=/output/uconsole-phase1-cm5.img
DOSFSTOOLS=/input/dosfstools.pkg.tar.xz
MTOOLS=/input/mtools.pkg.tar.xz
ACTION=${UCONSOLE_IMAGE_ACTION:-}
DISK_ID=${UCONSOLE_DISK_ID:-}
BOOT_ID=${UCONSOLE_BOOT_ID:-}
ROOT_UUID=${UCONSOLE_ROOT_UUID:-}
SOURCE_DATE_EPOCH=${UCONSOLE_SOURCE_DATE_EPOCH:-}
IMAGE_BYTES=8589934592
BOOT_OFFSET=4194304
BOOT_SIZE_BYTES=536870912
ROOT_OFFSET=541065216
ROOT_SIZE_BYTES=8047820800
BOOT_LOOP_DEVICE=''
ROOT_LOOP_DEVICE=''
MOUNT_ROOT=''
BOOT_MOUNTED=0
ROOT_MOUNTED=0
RUN_MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $RUN_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT/run" || status=1; fi
  if [[ $BOOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT/boot" || status=1; fi
  if [[ $ROOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT" || status=1; fi
  if [[ -n "$ROOT_LOOP_DEVICE" ]]; then losetup -d "$ROOT_LOOP_DEVICE" || status=1; fi
  if [[ -n "$BOOT_LOOP_DEVICE" ]]; then losetup -d "$BOOT_LOOP_DEVICE" || status=1; fi
  if [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]]; then rmdir "$MOUNT_ROOT" || status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$ACTION" == check || "$ACTION" == build || "$ACTION" == inspect ]] || fail 'image action is missing or unsafe'
[[ -f "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'real operator configuration state is missing'
for forbidden_state in hyprland-selection omarchy-shell-selection; do
  [[ ! -e "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/$forbidden_state" ]] || fail "desktop state is forbidden in Phase 1: $forbidden_state"
done

BUILD_ARGS=(
  --root-tree "$ROOT_TREE"
  --output "$OUTPUT"
  --size-mib 8192
  --boot-mib 512
  --disk-id "$DISK_ID"
  --boot-id "$BOOT_ID"
  --root-uuid "$ROOT_UUID"
  --source-date-epoch "$SOURCE_DATE_EPOCH"
)
if [[ "$ACTION" == check ]]; then
  [[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'check output must be empty'
  /repo/scripts/build-image.sh --plan "${BUILD_ARGS[@]}" || fail 'production Phase 1 image plan failed'
  [[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'image plan changed the output directory'
  printf '[PASS] production Phase 1 image plan completed without output\n'
  exit 0
fi

pacman -U --needed --noconfirm "$DOSFSTOOLS" "$MTOOLS" || fail 'unable to install pinned disposable image tools'
if [[ "$ACTION" == build ]]; then
  [[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'build output must be empty'
  /repo/scripts/build-image.sh --build "${BUILD_ARGS[@]}" || fail 'production Phase 1 image build failed'
else
  [[ -f "$OUTPUT" && ! -L "$OUTPUT" && -f "${OUTPUT}.manifest.json" && ! -L "${OUTPUT}.manifest.json" ]] || fail 'inspection image or manifest is missing or unsafe'
  [[ $(find /output -mindepth 1 -maxdepth 1 -print | wc -l) -eq 2 ]] || fail 'inspection output contains unexpected entries'
fi

[[ -f "$OUTPUT" && ! -b "$OUTPUT" && $(stat -c '%s' "$OUTPUT") -eq $IMAGE_BYTES ]] || fail 'completed Phase 1 image identity differs'
MANIFEST="${OUTPUT}.manifest.json"
grep -Fq '"image_size": 8589934592' "$MANIFEST" || fail 'manifest image size differs'
grep -Fq '"omarchy_image_state": "not-required"' "$MANIFEST" || fail 'manifest desktop state differs'
grep -Fq "\"disk_id\": \"$DISK_ID\"" "$MANIFEST" || fail 'manifest disk ID differs'
grep -Fq "\"volume_id\": \"$BOOT_ID\"" "$MANIFEST" || fail 'manifest boot ID differs'
grep -Fq "\"uuid\": \"$ROOT_UUID\"" "$MANIFEST" || fail 'manifest root UUID differs'

SFDISK_JSON=$(sfdisk --json "$OUTPUT") || fail 'unable to inspect Phase 1 partition table'
printf '%s\n' "$SFDISK_JSON" | grep -Fq "\"id\": \"0x$DISK_ID\"" || fail 'MBR disk ID differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 8192' || fail 'boot start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 1048576' || fail 'boot size differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 1056768' || fail 'root start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 15718400' || fail 'root size differs'

BOOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach boot range read-only'
ROOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach root range read-only'
EXPECTED_FAT_UUID="${BOOT_ID:0:4}-${BOOT_ID:4:4}"
[[ $(blkid -s UUID -o value "$BOOT_LOOP_DEVICE") == "$EXPECTED_FAT_UUID" ]] || fail 'FAT UUID differs'
[[ $(blkid -s UUID -o value "$ROOT_LOOP_DEVICE") == "$ROOT_UUID" ]] || fail 'ext4 UUID differs'
[[ $(blkid -s LABEL -o value "$ROOT_LOOP_DEVICE") == uconsole-root ]] || fail 'ext4 label differs'

MOUNT_ROOT=$(mktemp -d /work/phase1-image-inspect.XXXXXX) || fail 'unable to create image inspection mount'
mount -o ro "$ROOT_LOOP_DEVICE" "$MOUNT_ROOT" || fail 'unable to mount image root read-only'
ROOT_MOUNTED=1
mount -o ro "$BOOT_LOOP_DEVICE" "$MOUNT_ROOT/boot" || fail 'unable to mount image boot read-only'
BOOT_MOUNTED=1

for state_name in rootfs-selection build-prerequisites-selection hardware-selection base-system-packages base-system-selection; do
  cmp -s "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/$state_name" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/$state_name" || fail "selection state was not preserved: $state_name"
done
for forbidden_state in hyprland-selection omarchy-shell-selection; do
  [[ ! -e "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/$forbidden_state" ]] || fail "desktop state entered Phase 1 image: $forbidden_state"
done
IMAGE_STATE="$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/image-selection"
grep -Fqx "disk_id=$DISK_ID" "$IMAGE_STATE" || fail 'embedded disk identity differs'
grep -Fqx "boot_id=$BOOT_ID" "$IMAGE_STATE" || fail 'embedded boot identity differs'
grep -Fqx "root_uuid=$ROOT_UUID" "$IMAGE_STATE" || fail 'embedded root identity differs'
grep -Fqx "source_date_epoch=$SOURCE_DATE_EPOCH" "$IMAGE_STATE" || fail 'embedded source epoch differs'
grep -Fqx 'omarchy_image_state=not-required' "$IMAGE_STATE" || fail 'embedded desktop state differs'
grep -Fqx "PARTUUID=$DISK_ID-02  /      ext4  defaults,noatime  0 1" "$MOUNT_ROOT/etc/fstab" || fail 'rendered root fstab differs'
grep -Fqx "root=PARTUUID=$DISK_ID-02 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes" "$MOUNT_ROOT/boot/cmdline.txt" || fail 'rendered kernel command line differs'
grep -Fq '"path": "kernel8.img"' "$MOUNT_ROOT/boot/uconsole-build-manifest.json" || fail 'boot manifest lacks kernel'
[[ ! -e "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/image-selection" ]] || fail 'read-only source acquired image state'

mount -t tmpfs -o rw,nosuid,nodev tmpfs "$MOUNT_ROOT/run" || fail 'unable to create transient image inspection /run'
RUN_MOUNTED=1
UCONSOLE_INSPECTION_ROOT="$MOUNT_ROOT" /repo/research/container/inspect-phase1-configured-root-inside.sh || fail 'configured policy inspection failed inside image'
umount "$MOUNT_ROOT/run" || fail 'unable to remove transient image inspection /run'
RUN_MOUNTED=0

IMAGE_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}') || fail 'unable to hash completed Phase 1 image'
grep -Fq "\"image_sha256\": \"$IMAGE_SHA\"" "$MANIFEST" || fail 'manifest image digest differs'
printf '[PASS] Phase 1 image SHA-256 %s\n' "$IMAGE_SHA"
printf '[PASS] partition/filesystem identities, manifests and exact lower-layer states verified read-only\n'
printf '[PASS] effective configured policy survived image assembly; desktop state remains absent\n'
printf '[PASS] source volume remained read-only and no physical device was opened\n'
