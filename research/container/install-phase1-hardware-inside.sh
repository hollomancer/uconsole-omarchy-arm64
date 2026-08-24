#!/usr/bin/env bash

# Runs the exact prerequisite and selected hardware transactions inside the
# retained Linux root volume. Privilege is used only for bounded chroot mounts.

set -u
set -o pipefail

ROOT=/output/root
CHROOT=/usr/bin/chroot
ROOT_MOUNTED=0
DEV_MOUNTED=0
PROC_MOUNTED=0
SYS_MOUNTED=0
RUN_MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $RUN_MOUNTED -eq 1 ]]; then umount -R "$ROOT/run" || status=1; fi
  if [[ $SYS_MOUNTED -eq 1 ]]; then umount -R "$ROOT/sys" || status=1; fi
  if [[ $PROC_MOUNTED -eq 1 ]]; then umount "$ROOT/proc" || status=1; fi
  if [[ $DEV_MOUNTED -eq 1 ]]; then umount -R "$ROOT/dev" || status=1; fi
  if [[ $ROOT_MOUNTED -eq 1 ]]; then umount "$ROOT" || status=1; fi
  exit "$status"
}
trap cleanup_mounts EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$ROOT/etc/os-release" && -d "$ROOT/var/lib/pacman/local" ]] || fail 'retained Arch root is missing'
mount --bind "$ROOT" "$ROOT" || fail 'unable to make target root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make target root mount private'
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" || fail 'unable to create chroot mount points'
mount --rbind /dev "$ROOT/dev" || fail 'unable to bind /dev into target'
DEV_MOUNTED=1
mount --make-rslave "$ROOT/dev" || fail 'unable to make target /dev bind private'
mount -t proc proc "$ROOT/proc" || fail 'unable to mount target /proc'
PROC_MOUNTED=1
mount --rbind /sys "$ROOT/sys" || fail 'unable to bind /sys into target'
SYS_MOUNTED=1
mount --make-rslave "$ROOT/sys" || fail 'unable to make target /sys bind private'
mount --rbind /run "$ROOT/run" || fail 'unable to bind /run into target'
RUN_MOUNTED=1
mount --make-rslave "$ROOT/run" || fail 'unable to make target /run bind private'

/repo/scripts/install-uconsole-prerequisites.sh \
  --apply \
  --root "$ROOT" \
  --package-dir /input \
  --chroot-command "$CHROOT" || fail 'prerequisite transaction failed'

/repo/scripts/install-uconsole-hardware.sh \
  --apply \
  --root "$ROOT" \
  --kernel linux-rpi-16k \
  --kernel-package /input/linux-rpi-16k-6.18.45-1-aarch64.pkg.tar.xz \
  --headers-package /input/linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz \
  --board-package /input/uconsole-board-package-phase1/uconsole-cm5-dkms-0.1.r0.gbf7a0ab-1-aarch64.pkg.tar.xz \
  --chroot-command "$CHROOT" || fail 'hardware transaction failed'

[[ $("$CHROOT" "$ROOT" pacman -Q linux-rpi-16k) == 'linux-rpi-16k 6.18.45-1' ]] || fail 'selected kernel query differs'
[[ $("$CHROOT" "$ROOT" pacman -Q linux-rpi-16k-headers) == 'linux-rpi-16k-headers 6.18.45-1' ]] || fail 'selected headers query differs'
[[ $("$CHROOT" "$ROOT" pacman -Q uconsole-cm5-dkms) == 'uconsole-cm5-dkms 0.1.r0.gbf7a0ab-1' ]] || fail 'board package query differs'
[[ $("$CHROOT" "$ROOT" pacman -Q e2fsprogs) == 'e2fsprogs 1.47.4-1' ]] || fail 'filesystem tools query differs'
if "$CHROOT" "$ROOT" pacman -Q linux-aarch64 >/dev/null 2>&1; then fail 'generic kernel remains installed'; fi
if "$CHROOT" "$ROOT" pacman -Q uboot-raspberrypi >/dev/null 2>&1; then fail 'conflicting U-Boot package remains installed'; fi
DKMS_STATUS=$("$CHROOT" "$ROOT" dkms status -m uconsole-cm5 -v 0.1 -k 6.18.45-1-rpi-16k) || fail 'final DKMS query failed'
[[ "$DKMS_STATUS" == *installed* ]] || fail 'final DKMS status is not installed'
[[ -s "$ROOT/boot/kernel8.img" && -s "$ROOT/boot/initramfs-linux.img" ]] || fail 'kernel or initramfs is missing'
[[ -s "$ROOT/boot/overlays/uconsole-cm5-base.dtbo" && -s "$ROOT/boot/overlays/uconsole-audio-cm5.dtbo" ]] || fail 'uConsole overlays are missing'
[[ $(grep -Fxc '# BEGIN uconsole-omarchy-arm64 hardware include' "$ROOT/boot/config.txt") -eq 1 ]] || fail 'managed hardware include count differs'
grep -Fqx 'include uconsole-cm5.txt' "$ROOT/boot/config.txt" || fail 'managed uConsole include is inactive'
grep -Fqx 'board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a' "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" || fail 'hardware selection state differs'
grep -Fqx 'rootfs_sha256=f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967' "$ROOT/var/lib/uconsole-omarchy-arm64/rootfs-selection" || fail 'rootfs selection state was lost'

printf '[PASS] Phase 1 hardware root exact packages, DKMS, initramfs, overlays and boot include verified\n'
printf '[PASS] mount boundary temporary chroot mounts will be removed on exit\n'
