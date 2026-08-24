#!/usr/bin/env bash

# Build, filesystem-check and inspect the exact 8 GiB synthetic desktop image.
# This runs only inside the privileged disposable ARM64 build container.

set -u
set -o pipefail

ROOT_TREE=/source/root
OUTPUT=/output/uconsole-omarchy-prepared-integration.img
DOSFSTOOLS=/input/dosfstools.pkg.tar.xz
MTOOLS=/input/mtools.pkg.tar.xz
IMAGE_BYTES=8589934592
BOOT_OFFSET=4194304
BOOT_SIZE_BYTES=536870912
ROOT_OFFSET=541065216
ROOT_SIZE_BYTES=8047820800
MIN_FREE_KIB=6291456
BOOT_LOOP_DEVICE=''
ROOT_LOOP_DEVICE=''
MOUNT_ROOT=''
BOOT_MOUNTED=0
ROOT_MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local cleanup_status=$?
  trap - EXIT INT TERM
  if [[ $BOOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT/boot" || cleanup_status=1; fi
  if [[ $ROOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT" || cleanup_status=1; fi
  if [[ -n "$ROOT_LOOP_DEVICE" ]]; then losetup -d "$ROOT_LOOP_DEVICE" || cleanup_status=1; fi
  if [[ -n "$BOOT_LOOP_DEVICE" ]]; then losetup -d "$BOOT_LOOP_DEVICE" || cleanup_status=1; fi
  if [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]]; then rmdir "$MOUNT_ROOT" || cleanup_status=1; fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/user-preparation-integration" ]] || fail 'prepared user state is missing from source'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output volume must be empty'
OUTPUT_FREE_KIB=$(df -Pk /output | awk 'NR == 2 { print $4 }') || fail 'unable to measure output-volume free space'
[[ "$OUTPUT_FREE_KIB" =~ ^[0-9]+$ ]] || fail 'invalid output-volume free-space measurement'
((OUTPUT_FREE_KIB >= MIN_FREE_KIB)) || fail 'output volume has less than the 6 GiB build minimum'
mkdir -p /work || fail 'unable to create integration work directory'
pacman -U --needed --noconfirm "$DOSFSTOOLS" "$MTOOLS" || fail 'unable to install pinned image tools into the disposable builder'

/repo/scripts/build-image.sh \
  --build \
  --root-tree "$ROOT_TREE" \
  --output "$OUTPUT" \
  --size-mib 8192 \
  --boot-mib 512 \
  --disk-id c05e2026 \
  --boot-id C05E2026 \
  --root-uuid 7a4cc8d5-70df-4f98-a88d-3b89c9f21561 \
  --source-date-epoch 1787590000 \
  --require-omarchy-prepared || fail 'prepared desktop image build failed'

[[ -f "$OUTPUT" && ! -b "$OUTPUT" && $(stat -c '%s' "$OUTPUT") -eq $IMAGE_BYTES ]] || fail 'completed image identity differs'
[[ -f "${OUTPUT}.manifest.json" ]] || fail 'external image manifest is missing'
grep -Fq '"image_size": 8589934592' "${OUTPUT}.manifest.json" || fail 'external image size differs'
grep -Fq '"omarchy_image_state": "prepared-inactive"' "${OUTPUT}.manifest.json" || fail 'external image activation state differs'

SFDISK_JSON=$(sfdisk --json "$OUTPUT") || fail 'unable to inspect image partition table'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"id": "0xc05e2026"' || fail 'image MBR ID differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 8192' || fail 'boot start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 1048576' || fail 'boot size differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 1056768' || fail 'root start differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 15718400' || fail 'root size differs'

BOOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach boot range read-only'
ROOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$OUTPUT") || fail 'unable to attach root range read-only'
[[ $(blkid -s UUID -o value "$BOOT_LOOP_DEVICE") == C05E-2026 ]] || fail 'FAT UUID differs'
[[ $(blkid -s UUID -o value "$ROOT_LOOP_DEVICE") == 7a4cc8d5-70df-4f98-a88d-3b89c9f21561 ]] || fail 'ext4 UUID differs'
[[ $(blkid -s LABEL -o value "$ROOT_LOOP_DEVICE") == uconsole-root ]] || fail 'ext4 label differs'

MOUNT_ROOT=$(mktemp -d /work/omarchy-prepared-image-inspect.XXXXXX) || fail 'unable to create inspection mount'
mount -o ro "$ROOT_LOOP_DEVICE" "$MOUNT_ROOT" || fail 'unable to mount root filesystem read-only'
ROOT_MOUNTED=1
mount -o ro "$BOOT_LOOP_DEVICE" "$MOUNT_ROOT/boot" || fail 'unable to mount boot filesystem read-only'
BOOT_MOUNTED=1

for state_name in hardware-selection base-system-packages base-system-selection hyprland-selection omarchy-shell-selection user-preparation-integration; do
  cmp -s "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/$state_name" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/$state_name" || fail "selection state was not preserved: $state_name"
done
grep -Fxq 'omarchy_image_state=prepared-inactive' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/image-selection" || fail 'embedded image activation state differs'
grep -Fxq 'session_activated=no' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" || fail 'shell state reports activation'
grep -Fxq 'uwsm_enabled=no' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" || fail 'shell state reports UWSM activation'
grep -Fxq 'activation=no' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" || fail 'user preparation reports activation'
grep -Fxq 'session_modified=no' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" || fail 'user preparation reports a session modification'

cmp -s /repo/config/hyprland/minimal.lua "$MOUNT_ROOT/home/integration/.config/hypr/hyprland.lua" || fail 'Hyprland user configuration differs'
cmp -s /repo/config/arm64-overrides/shell.json "$MOUNT_ROOT/home/integration/.config/omarchy/shell.json" || fail 'Omarchy shell user configuration differs'
cmp -s /repo/config/arm64-overrides/foot.ini "$MOUNT_ROOT/home/integration/.config/foot/foot.ini" || fail 'Foot user configuration differs'
[[ $(readlink "$MOUNT_ROOT/home/integration/.local/state/omarchy/current/theme") == /usr/share/omarchy-arm64/themes/tokyo-night ]] || fail 'initial theme link differs'
[[ $(readlink "$MOUNT_ROOT/home/integration/.local/state/omarchy/current/background") == /usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp ]] || fail 'initial background link differs'

[[ $(pacman --root "$MOUNT_ROOT" -Q quickshell) == 'quickshell 0.3.1-1' ]] || fail 'Quickshell package differs'
[[ $(pacman --root "$MOUNT_ROOT" -Q omarchy-arm64-userland) == 'omarchy-arm64-userland 4.0.0.alpha-3' ]] || fail 'thin Omarchy package differs'
REQUIRED_COMMANDS=0
while IFS='|' read -r command_name provider disposition reason extra; do
  [[ -n "$command_name" && "$command_name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid runtime policy row: $command_name"
  [[ "$disposition" != inactive-optional ]] || continue
  chroot "$MOUNT_ROOT" /usr/bin/bash --noprofile --norc -c "command -v -- '$command_name' >/dev/null" || fail "runtime command is absent: $command_name"
  REQUIRED_COMMANDS=$((REQUIRED_COMMANDS + 1))
  : "$provider" "$reason"
done < /repo/config/arm64-overrides/omarchy-runtime-command-policy.tsv
[[ $REQUIRED_COMMANDS -eq 51 ]] || fail 'required runtime command count differs'

[[ -z "$(find "$MOUNT_ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'image contains cloned SSH host keys'
grep -Fqx 'PARTUUID=c05e2026-02  /      ext4  defaults,noatime  0 1' "$MOUNT_ROOT/etc/fstab" || fail 'root fstab differs'
grep -Fqx 'root=PARTUUID=c05e2026-02 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes' "$MOUNT_ROOT/boot/cmdline.txt" || fail 'kernel command line differs'
grep -Fq '"path": "kernel8.img"' "$MOUNT_ROOT/boot/uconsole-build-manifest.json" || fail 'boot manifest lacks the kernel'
[[ ! -e "$ROOT_TREE/var/lib/uconsole-omarchy-arm64/image-selection" ]] || fail 'read-only source acquired image state'

IMAGE_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}') || fail 'unable to hash completed image'
grep -Fq "\"image_sha256\": \"$IMAGE_SHA\"" "${OUTPUT}.manifest.json" || fail 'external image digest differs'
printf '[PASS] prepared desktop image sha256=%s\n' "$IMAGE_SHA"
printf '[PASS] exact hardware/base/Hyprland/Omarchy states survived image assembly\n'
printf '[PASS] filesystems, partition identities, manifests and 51 runtime commands verified read-only\n'
printf '[PASS] shell remains prepared-inactive; no UWSM or session handoff is enabled\n'
printf '[WARN] image contains synthetic integration credentials and must never be written or published\n'
