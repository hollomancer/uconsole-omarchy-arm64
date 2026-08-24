#!/usr/bin/env bash

# Native-aarch64 in-place integration against a disposable Hyprland volume.

set -u
set -o pipefail

ROOT=/target/root
CHROOT=/usr/bin/chroot
ROOT_MOUNTED=0
DEV_MOUNTED=0
PROC_MOUNTED=0
SYS_MOUNTED=0
RUN_MOUNTED=0
PACKAGE_DIR_MOUNTED=0
PACKAGE_VIEW=/run/uconsole-omarchy-shell-packages
USERLAND_FILENAME=omarchy-arm64-userland-4.0.0.alpha-3-any.pkg.tar.xz

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $PACKAGE_DIR_MOUNTED -eq 1 ]]; then umount -R "$ROOT$PACKAGE_VIEW" || status=1; fi
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

tree_manifest() {
  local directory=$1
  local relative=''
  local target=''
  while IFS= read -r relative; do
    relative=${relative#./}
    if [[ -L "$directory/$relative" ]]; then
      target=$(readlink "$directory/$relative") || return 1
      printf 'link|%s|%s\n' "$relative" "$target"
    elif [[ -f "$directory/$relative" ]]; then
      printf 'file|%s|%s|%s\n' "$relative" "$(stat -c '%a:%u:%g' "$directory/$relative")" "$(sha256sum "$directory/$relative" | awk '{print $1}')"
    fi
  done < <(cd -- "$directory" && find . \( -type f -o -type l \) -print | LC_ALL=C sort)
}

[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || fail 'exact Hyprland state is missing'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" ]] || fail 'volume already has an Omarchy shell transaction'
[[ ! -e "$ROOT/home/integration/.config/omarchy" && ! -e "$ROOT/home/integration/.config/foot" ]] || fail 'volume already has an Omarchy/Foot home seed'
tree_manifest "$ROOT/boot" > /tmp/boot.before || fail 'unable to snapshot boot tree'
for state_name in hardware-selection base-system-packages base-system-selection hyprland-selection; do
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/$state_name" >> /tmp/layer.before || fail "unable to snapshot state: $state_name"
done
sha256sum "$ROOT/home/integration/.config/hypr/hyprland.lua" >> /tmp/layer.before || fail 'unable to snapshot Hyprland config'

mount --bind "$ROOT" "$ROOT" || fail 'unable to make target root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make target root private'
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" || fail 'unable to create chroot mount points'
mount --rbind /dev "$ROOT/dev" || fail 'unable to bind /dev'
DEV_MOUNTED=1
mount --make-rslave "$ROOT/dev" || fail 'unable to isolate target /dev'
mount -t proc proc "$ROOT/proc" || fail 'unable to mount target /proc'
PROC_MOUNTED=1
mount --rbind /sys "$ROOT/sys" || fail 'unable to bind /sys'
SYS_MOUNTED=1
mount --make-rslave "$ROOT/sys" || fail 'unable to isolate target /sys'
mount --rbind /run "$ROOT/run" || fail 'unable to bind /run'
RUN_MOUNTED=1
mount --make-rslave "$ROOT/run" || fail 'unable to isolate target /run'

mkdir "$ROOT$PACKAGE_VIEW" || fail 'unable to create package view'
mount -t tmpfs -o size=2m,nodev,nosuid,noexec tmpfs "$ROOT$PACKAGE_VIEW" || fail 'unable to mount package-only tmpfs view'
PACKAGE_DIR_MOUNTED=1
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" && -f "/packages/$filename" ]] || fail "invalid package-view input: $name"
  : > "$ROOT$PACKAGE_VIEW/$filename" || fail "unable to create package mount point: $filename"
  mount --bind "/packages/$filename" "$ROOT$PACKAGE_VIEW/$filename" || fail "unable to bind package payload: $filename"
  mount -o remount,bind,ro "$ROOT$PACKAGE_VIEW/$filename" || fail "unable to make package payload read-only: $filename"
  : "$version" "$architecture" "$repository" "$kind" "$digest" "$signature_digest" "$size"
done < /repo/config/omarchy-shell/transaction.lock
: > "$ROOT$PACKAGE_VIEW/$USERLAND_FILENAME" || fail 'unable to create local package mount point'
mount --bind "/userland/$USERLAND_FILENAME" "$ROOT$PACKAGE_VIEW/$USERLAND_FILENAME" || fail 'unable to bind local package payload'
mount -o remount,bind,ro "$ROOT$PACKAGE_VIEW/$USERLAND_FILENAME" || fail 'unable to make local package payload read-only'

INSTALL_ARGS=(
  --root "$ROOT"
  --user integration
  --package-dir /packages
  --package-dir-in-root "$PACKAGE_VIEW"
  --userland-package "/userland/$USERLAND_FILENAME"
  --userland-package-in-root "$PACKAGE_VIEW/$USERLAND_FILENAME"
  --chroot-command "$CHROOT"
)
if ! /repo/scripts/install-omarchy-shell.sh --plan "${INSTALL_ARGS[@]}" > /tmp/omarchy-shell-plan.log 2>&1; then
  tail -n 100 /tmp/omarchy-shell-plan.log >&2
  fail 'Omarchy shell plan failed'
fi
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" ]] || fail 'plan mode wrote shell state'
[[ ! -e "$ROOT/usr/share/omarchy-arm64" ]] || fail 'plan mode installed userland'

if ! /repo/scripts/install-omarchy-shell.sh --apply "${INSTALL_ARGS[@]}" > /tmp/omarchy-shell-apply.log 2>&1; then
  tail -n 120 /tmp/omarchy-shell-apply.log >&2
  fail 'Omarchy shell apply failed'
fi
if ! /repo/scripts/install-omarchy-shell.sh --apply "${INSTALL_ARGS[@]}" > /tmp/omarchy-shell-reapply.log 2>&1; then
  tail -n 120 /tmp/omarchy-shell-reapply.log >&2
  fail 'Omarchy shell idempotent reapply failed'
fi

TRANSACTION_COUNT=0
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid transaction row after apply: $name"
  [[ $("$CHROOT" "$ROOT" pacman -Q "$name") == "$name $version" ]] || fail "installed transaction package differs: $name"
  TRANSACTION_COUNT=$((TRANSACTION_COUNT + 1))
  : "$architecture" "$repository" "$kind" "$digest" "$signature_digest" "$filename" "$size"
done < /repo/config/omarchy-shell/transaction.lock
[[ $TRANSACTION_COUNT -eq 24 ]] || fail "transaction count differs: $TRANSACTION_COUNT"
[[ $("$CHROOT" "$ROOT" pacman -Q omarchy-arm64-userland) == 'omarchy-arm64-userland 4.0.0.alpha-3' ]] || fail 'local userland package differs'

REQUIRED_COMMANDS=0
while IFS='|' read -r command_name provider disposition reason extra; do
  [[ -n "$command_name" && "$command_name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid runtime policy row: $command_name"
  [[ "$disposition" != inactive-optional ]] || continue
  "$CHROOT" "$ROOT" pacman -Q "$provider" >/dev/null || fail "runtime provider is absent: $provider"
  "$CHROOT" "$ROOT" /usr/bin/bash --noprofile --norc -c "command -v -- '$command_name' >/dev/null" || fail "runtime command is absent: $command_name"
  REQUIRED_COMMANDS=$((REQUIRED_COMMANDS + 1))
  : "$reason"
done < /repo/config/arm64-overrides/omarchy-runtime-command-policy.tsv
[[ $REQUIRED_COMMANDS -eq 51 ]] || fail "runtime command count differs: $REQUIRED_COMMANDS"

[[ $("$CHROOT" "$ROOT" fc-match -f '%{family[0]}\n' monospace) == 'JetBrainsMono Nerd Font' ]] || fail 'monospace font does not resolve to JetBrainsMono Nerd Font'
[[ -f "$ROOT/usr/share/fonts/omarchy/omarchy.ttf" ]] || fail 'Omarchy icon font is absent'
cmp -s /repo/config/arm64-overrides/themes/tokyo-night/foot.ini "$ROOT/usr/share/omarchy-arm64/themes/tokyo-night/foot.ini" || fail 'rendered Foot theme differs'
cmp -s /repo/config/arm64-overrides/themes/tokyo-night/shell.toml "$ROOT/usr/share/omarchy-arm64/themes/tokyo-night/shell.toml" || fail 'rendered shell theme differs'

tree_manifest "$ROOT/boot" > /tmp/boot.after || fail 'unable to resnapshot boot tree'
cmp -s /tmp/boot.before /tmp/boot.after || fail 'boot tree changed during userland installation'
for state_name in hardware-selection base-system-packages base-system-selection hyprland-selection; do
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/$state_name" >> /tmp/layer.after || fail "unable to resnapshot state: $state_name"
done
sha256sum "$ROOT/home/integration/.config/hypr/hyprland.lua" >> /tmp/layer.after || fail 'unable to resnapshot Hyprland config'
cmp -s /tmp/layer.before /tmp/layer.after || fail 'hardware, base-system, or Hyprland state changed'

STATE="$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection"
[[ $(awk 'END {print NR}' "$STATE") -eq 14 ]] || fail 'Omarchy shell state field count differs'
grep -Fxq 'userland_version=4.0.0.alpha-3' "$STATE" || fail 'userland version state differs'
grep -Fxq 'transaction_packages=24' "$STATE" || fail 'transaction count state differs'
grep -Fxq 'runtime_commands=51' "$STATE" || fail 'runtime command state differs'
grep -Fxq 'target_user=integration' "$STATE" || fail 'target user state differs'
grep -Fxq 'home_seeded=no' "$STATE" || fail 'home seed state differs'
grep -Fxq 'session_activated=no' "$STATE" || fail 'session activation state differs'
grep -Fxq 'uwsm_enabled=no' "$STATE" || fail 'UWSM state differs'
grep -Fxq 'hardware_owned=no' "$STATE" || fail 'hardware ownership state differs'
grep -Fxq 'updates_owned=no' "$STATE" || fail 'update ownership state differs'
[[ ! -e "$ROOT/home/integration/.config/omarchy" && ! -e "$ROOT/home/integration/.config/foot" ]] || fail 'package transaction seeded the user home'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" ]] || fail 'package transaction prepared the user'
for unit in uwsm-app@.service sddm.service greetd.service; do
  unit_state=$("$CHROOT" "$ROOT" systemctl is-enabled "$unit" 2>/dev/null)
  case "$unit_state" in enabled|enabled-runtime|linked|linked-runtime|alias) fail "graphical session unit was enabled: $unit" ;; esac
done

printf '[PASS] native ARM64 Omarchy shell transaction installed official=%s local=1\n' "$TRANSACTION_COUNT"
printf '[PASS] runtime command closure present commands=%s monospace=JetBrainsMono-Nerd\n' "$REQUIRED_COMMANDS"
printf '[PASS] boot, hardware, base-system and Hyprland state remained byte-identical\n'
printf '[PASS] no home seed, session, display manager, UWSM or update ownership was introduced\n'
printf '[PASS] retained disposable volume is ready for conflict-safe user preparation\n'
