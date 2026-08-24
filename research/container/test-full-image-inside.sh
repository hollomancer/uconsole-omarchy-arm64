#!/usr/bin/env bash

# Build and inspect a 4 GiB regular image from the configured clone. The image
# contains synthetic integration credentials and must never be published.

set -u
set -o pipefail

ROOT_TREE=/source/root
OUTPUT=/output/uconsole-integration.img
DOSFSTOOLS=/input/dosfstools.pkg.tar.xz
MTOOLS=/input/mtools.pkg.tar.xz
BOOT_OFFSET=4194304
BOOT_SIZE_BYTES=536870912
ROOT_OFFSET=541065216
ROOT_SIZE_BYTES=3752853504

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$ROOT_TREE/etc/os-release" && -f "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'configured source root is missing'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output volume must be empty'
mkdir -p /work || fail 'unable to create integration work directory'
pacman -U --needed --noconfirm "$DOSFSTOOLS" "$MTOOLS" || fail 'unable to install pinned image tools'

/repo/scripts/build-image.sh \
  --build \
  --root-tree "$ROOT_TREE" \
  --output "$OUTPUT" \
  --size-mib 4096 \
  --boot-mib 512 \
  --disk-id c05e2026 \
  --boot-id C05E2026 \
  --root-uuid 7a4cc8d5-70df-4f98-a88d-3b89c9f21561 \
  --source-date-epoch 1787590000 || fail 'configured full-root image build failed'

[[ -f "$OUTPUT" && ! -b "$OUTPUT" && $(stat -c '%s' "$OUTPUT") -eq 4294967296 ]] || fail 'completed image identity differs'
[[ -f "${OUTPUT}.manifest.json" ]] || fail 'external image manifest is missing'
grep -Fq '"disk_id": "c05e2026"' "${OUTPUT}.manifest.json" || fail 'external manifest disk ID differs'
grep -Fq '"image_size": 4294967296' "${OUTPUT}.manifest.json" || fail 'external manifest image size differs'

SFDISK_JSON=$(sfdisk --json "$OUTPUT") || fail 'unable to inspect full image partition table'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"id": "0xc05e2026"' || fail 'full image MBR ID differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 8192' || fail 'full image boot start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 1048576' || fail 'full image boot size differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 1056768' || fail 'full image root start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 7329792' || fail 'full image root size differs'

BOOT_LOOP_DEVICE=''
ROOT_LOOP_DEVICE=''
MOUNT_ROOT=''
BOOT_MOUNTED=0
ROOT_MOUNTED=0
cleanup() {
  local status=$?
  trap - EXIT INT TERM
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

BOOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach full boot range read-only'
ROOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach full root range read-only'
[[ $(blkid -s UUID -o value "$BOOT_LOOP_DEVICE") == C05E-2026 ]] || fail 'full FAT UUID differs'
[[ $(blkid -s UUID -o value "$ROOT_LOOP_DEVICE") == 7a4cc8d5-70df-4f98-a88d-3b89c9f21561 ]] || fail 'full ext4 UUID differs'
[[ $(blkid -s LABEL -o value "$ROOT_LOOP_DEVICE") == uconsole-root ]] || fail 'full ext4 label differs'

MOUNT_ROOT=$(mktemp -d /work/full-image-inspect.XXXXXX) || fail 'unable to create full-image inspection mount'
mount -o ro "$ROOT_LOOP_DEVICE" "$MOUNT_ROOT" || fail 'unable to mount full root read-only'
ROOT_MOUNTED=1
mount -o ro "$BOOT_LOOP_DEVICE" "$MOUNT_ROOT/boot" || fail 'unable to mount full boot read-only'
BOOT_MOUNTED=1

cmp -s "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/hardware-selection" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" || fail 'hardware selection was not preserved in full image'
cmp -s "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-packages" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages" || fail 'base package state was not preserved in full image'
cmp -s "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-selection" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" || fail 'base selection was not preserved in full image'
ADMIN_USER=$(awk -F '=' '$1 == "admin_user" { print $2 }' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection") || fail 'unable to read full-image admin'
[[ "$ADMIN_USER" == integration ]] || fail 'synthetic full-image admin differs'
awk -F ':' '$1 == "root" { found=1; valid=($2 ~ /^!/) } END { exit !(found && valid) }' "$MOUNT_ROOT/etc/shadow" || fail 'full-image root account is not locked'
awk -F ':' '$1 == "alarm" { found=1; valid=($2 ~ /^!/) } END { exit !(found && valid) }' "$MOUNT_ROOT/etc/shadow" || fail 'full-image source alarm account is not locked'
awk -F ':' '$1 == "integration" { found=1; valid=($2 ~ /^\$6\$/) } END { exit !(found && valid) }' "$MOUNT_ROOT/etc/shadow" || fail 'full-image admin recovery hash differs'
[[ $(stat -c '%a' "$MOUNT_ROOT/home/integration/.ssh/authorized_keys") == 600 ]] || fail 'full-image authorized_keys mode differs'
[[ $(stat -c '%a' "$MOUNT_ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection") == 600 ]] || fail 'full-image Wi-Fi mode differs'
[[ -z "$(find "$MOUNT_ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'full image contains cloned SSH host keys'
grep -Fqx 'PARTUUID=c05e2026-02  /      ext4  defaults,noatime  0 1' "$MOUNT_ROOT/etc/fstab" || fail 'full-image root fstab differs'
grep -Fqx 'root=PARTUUID=c05e2026-02 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes' "$MOUNT_ROOT/boot/cmdline.txt" || fail 'full-image kernel command line differs'
grep -Fq '"path": "kernel8.img"' "$MOUNT_ROOT/boot/uconsole-build-manifest.json" || fail 'full-image boot manifest lacks kernel'
grep -Fqx 'root_uuid=7a4cc8d5-70df-4f98-a88d-3b89c9f21561' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/image-selection" || fail 'full-image selection state differs'
[[ ! -e "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/image-selection" ]] || fail 'read-only configured source acquired image state'

IMAGE_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}') || fail 'unable to hash completed full image'
grep -Fq "\"image_sha256\": \"$IMAGE_SHA\"" "${OUTPUT}.manifest.json" || fail 'external manifest image digest differs'
printf '[PASS] configured full-root image sha256=%s\n' "$IMAGE_SHA"
printf '[PASS] image preserves hardware/base state, locked accounts, key-only access and unique-host-key boundary\n'
printf '[WARN] image contains synthetic integration credentials and must never be written or published\n'
