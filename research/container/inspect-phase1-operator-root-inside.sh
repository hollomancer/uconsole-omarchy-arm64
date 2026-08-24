#!/usr/bin/env bash

# Fail-closed read-only inspection of the exact pre-configuration root state.

set -u
set -o pipefail

ROOT=/source/root
STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

state_field() {
  local file=$1
  local key=$2
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$file"
}

account_is_locked() {
  local account=$1
  awk -F ':' -v wanted="$account" '$1 == wanted { found=1; locked=($2 ~ /^!|^\*/) } END { exit !(found && locked) }' "$ROOT/etc/shadow"
}

[[ -f "$ROOT/etc/os-release" && -d "$ROOT/var/lib/pacman/local" ]] || fail 'Arch Linux ARM root evidence is missing'
for state_name in rootfs-selection hardware-selection build-prerequisites-selection base-system-packages; do
  [[ -f "$STATE_DIR/$state_name" && ! -L "$STATE_DIR/$state_name" ]] || fail "required state is missing or unsafe: $state_name"
done
for absent_state in base-system-selection hyprland-selection omarchy-shell-selection; do
  [[ ! -e "$STATE_DIR/$absent_state" ]] || fail "upper-layer state is unexpectedly present: $absent_state"
done

[[ $(state_field "$STATE_DIR/rootfs-selection" rootfs_sha256) == f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967 ]] || fail 'rootfs digest state differs'
[[ $(state_field "$STATE_DIR/rootfs-selection" signature_fingerprint) == 68B3537F39A313B3E574D06777193F152BDBE6A6 ]] || fail 'rootfs signer state differs'
[[ $(state_field "$STATE_DIR/hardware-selection" kernel_package) == linux-rpi-16k ]] || fail 'kernel selection differs'
[[ $(state_field "$STATE_DIR/hardware-selection" kernel_release) == 6.18.45-1-rpi-16k ]] || fail 'kernel release differs'
[[ $(state_field "$STATE_DIR/hardware-selection" board_source_commit) == bf7a0ab55654c96b74d013520e1196d39f66391a ]] || fail 'board source state differs'
[[ $(chroot "$ROOT" pacman -Q linux-rpi-16k) == 'linux-rpi-16k 6.18.45-1' ]] || fail 'installed kernel package differs'
[[ $(chroot "$ROOT" pacman -Q uconsole-cm5-dkms) == 'uconsole-cm5-dkms 0.1.r0.gbf7a0ab-1' ]] || fail 'installed board package differs'
[[ $(chroot "$ROOT" pacman -Q networkmanager) == 'networkmanager 1.58.1-1' ]] || fail 'installed NetworkManager differs'
[[ $(chroot "$ROOT" pacman -Q bluez) == 'bluez 5.87-2' ]] || fail 'installed BlueZ differs'
[[ $(wc -l < "$STATE_DIR/base-system-packages") -eq 21 ]] || fail 'base-system package state count differs'
[[ -s "$ROOT/boot/kernel8.img" && -s "$ROOT/boot/initramfs-linux.img" ]] || fail 'kernel or initramfs is missing'
[[ -s "$ROOT/boot/overlays/uconsole-cm5-base.dtbo" && -s "$ROOT/boot/overlays/uconsole-audio-cm5.dtbo" ]] || fail 'uConsole overlay is missing'
[[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'SSH host identity is already baked into the root'

printf '[PASS] signed rootfs         pinned digest and signer state match\n'
printf '[PASS] hardware layer       linux-rpi-16k, DKMS, initramfs and overlays match\n'
printf '[PASS] base package layer   21 locked packages; NetworkManager and BlueZ match\n'
printf '[PASS] upper-layer boundary no base configuration, Hyprland or Omarchy state\n'
printf '[PASS] host identity        no baked SSH host key\n'
printf '[PASS] retained root size   %s KiB; %s filesystem entries\n' "$(du -sk "$ROOT" | awk '{print $1}')" "$(find "$ROOT" -xdev | wc -l)"
printf '[PASS] state digests        hardware=%s base-packages=%s\n' \
  "$(sha256sum "$STATE_DIR/hardware-selection" | awk '{print $1}')" \
  "$(sha256sum "$STATE_DIR/base-system-packages" | awk '{print $1}')"

if account_is_locked root; then printf '[PASS] source root account  already locked\n';
else printf '[WARN] source root account  retains rootfs credential state\n'; fi
if account_is_locked alarm; then printf '[PASS] source alarm account already locked\n';
else printf '[WARN] source alarm account retains rootfs credential state\n'; fi
printf '[WARN] operator boundary    configure private identity/access before imaging or booting\n'
