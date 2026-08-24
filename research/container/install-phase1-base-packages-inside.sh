#!/usr/bin/env bash

# Apply and verify the exact package-only base layer. The target deliberately
# retains the signed rootfs accounts until configure-base-system.sh consumes
# operator-selected private inputs.

set -u
set -o pipefail

ROOT=/output/root
CHROOT=/usr/bin/chroot
LOCK=/repo/config/base-system/packages.lock
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
[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" ]] || fail 'verified hardware state is missing'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'operator configuration already exists'
[[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'target already contains SSH host keys'

mount --bind "$ROOT" "$ROOT" || fail 'unable to make target root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make target root private'
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" || fail 'unable to create chroot mount points'
mount --rbind /dev "$ROOT/dev" || fail 'unable to bind /dev into target'
DEV_MOUNTED=1
mount --make-rslave "$ROOT/dev" || fail 'unable to isolate target /dev'
mount -t proc proc "$ROOT/proc" || fail 'unable to mount target /proc'
PROC_MOUNTED=1
mount --rbind /sys "$ROOT/sys" || fail 'unable to bind /sys into target'
SYS_MOUNTED=1
mount --make-rslave "$ROOT/sys" || fail 'unable to isolate target /sys'
mount --rbind /run "$ROOT/run" || fail 'unable to bind /run into target'
RUN_MOUNTED=1
mount --make-rslave "$ROOT/run" || fail 'unable to isolate target /run'

INSTALL_ARGS=(--root "$ROOT" --package-dir /input --chroot-command "$CHROOT")
/repo/scripts/install-base-system-packages.sh --plan "${INSTALL_ARGS[@]}" || fail 'base-system package plan failed'
/repo/scripts/install-base-system-packages.sh --apply "${INSTALL_ARGS[@]}" || fail 'base-system package transaction failed'
/repo/scripts/install-base-system-packages.sh --apply "${INSTALL_ARGS[@]}" || fail 'base-system package idempotent re-run failed'

STATE="$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages"
[[ -f "$STATE" && ! -L "$STATE" ]] || fail 'base-system package state is missing or unsafe'
[[ $(stat -c '%a' "$STATE") == 644 ]] || fail 'base-system package state mode differs'
EXPECTED_COUNT=0
while IFS='|' read -r name version architecture digest filename extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "unexpected package lock field for $name"
  [[ $("$CHROOT" "$ROOT" pacman -Q "$name") == "$name $version" ]] || fail "installed package differs: $name"
  [[ $(grep -Fxc "$name=$version" "$STATE") -eq 1 ]] || fail "selection state differs: $name"
  EXPECTED_COUNT=$((EXPECTED_COUNT + 1))
done < "$LOCK"
[[ $(wc -l < "$STATE") -eq $EXPECTED_COUNT ]] || fail 'base-system package state has unexpected entries'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'package stage created operator configuration state'
[[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'package stage created SSH host keys'
grep -Eq '^root:' "$ROOT/etc/shadow" || fail 'source root account state is missing'
grep -Eq '^alarm:' "$ROOT/etc/shadow" || fail 'source alarm account state is missing'

printf '[PASS] Phase 1 base package closure installed and idempotently verified\n'
printf '[PASS] no operator configuration, network secret or SSH host identity added\n'
printf '[WARN] source rootfs accounts remain operator-pending; do not image or boot this root\n'
