#!/usr/bin/env bash

set -u
set -o pipefail

ROOT=/target/root
ALIAS_MOUNTED=0
REPO_MOUNTED=0
SOURCE_MOUNTED=0
ROOT_MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $SOURCE_MOUNTED -eq 1 ]]; then umount "$ROOT/run/uconsole-omarchy-source.tar.gz" || status=1; fi
  if [[ $REPO_MOUNTED -eq 1 ]]; then umount -R "$ROOT/run/uconsole-prep-repo" || status=1; fi
  if [[ $ALIAS_MOUNTED -eq 1 ]]; then umount -R "$ROOT/run/uconsole-offline-root" || status=1; fi
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

[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" ]] || fail 'Omarchy shell package state is missing'
PREP_EXISTING=0
if [[ -e "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" ]]; then
  PREP_EXISTING=1
  tree_manifest "$ROOT/home/integration/.config" > /tmp/prep-home.before || fail 'unable to snapshot existing user configuration'
  tree_manifest "$ROOT/home/integration/.local/state/omarchy" >> /tmp/prep-home.before || fail 'unable to snapshot existing Omarchy state'
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" >> /tmp/prep-home.before || fail 'unable to snapshot existing preparation state'
else
  [[ ! -e "$ROOT/home/integration/.config/omarchy" && ! -e "$ROOT/home/integration/.config/foot" ]] || fail 'target user has configuration without preparation state'
fi
tree_manifest "$ROOT/boot" > /tmp/prep-boot.before || fail 'unable to snapshot boot tree'
for state_name in hardware-selection base-system-packages base-system-selection hyprland-selection omarchy-shell-selection; do
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/$state_name" >> /tmp/prep-layers.before || fail "unable to snapshot state: $state_name"
done
sha256sum "$ROOT/home/integration/.config/hypr/hyprland.lua" >> /tmp/prep-layers.before || fail 'unable to snapshot Hyprland config'

mount --bind "$ROOT" "$ROOT" || fail 'unable to make target root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make target root private'
mkdir -p "$ROOT/run/uconsole-offline-root" "$ROOT/run/uconsole-prep-repo" || fail 'unable to create preparation mount points'
: > "$ROOT/run/uconsole-omarchy-source.tar.gz" || fail 'unable to create source mount point'
mount --bind "$ROOT" "$ROOT/run/uconsole-offline-root" || fail 'unable to create offline root alias'
ALIAS_MOUNTED=1
mount --bind /repo "$ROOT/run/uconsole-prep-repo" || fail 'unable to bind repository into target root'
REPO_MOUNTED=1
mount -o remount,bind,ro "$ROOT/run/uconsole-prep-repo" || fail 'unable to make repository bind read-only'
mount --bind /source/omarchy.tar.gz "$ROOT/run/uconsole-omarchy-source.tar.gz" || fail 'unable to bind source archive into target root'
SOURCE_MOUNTED=1
mount -o remount,bind,ro "$ROOT/run/uconsole-omarchy-source.tar.gz" || fail 'unable to make source archive read-only'

PREPARER=/run/uconsole-prep-repo/scripts/prepare-omarchy-user.sh
ARGS=(--root /run/uconsole-offline-root --user integration --source-archive /run/uconsole-omarchy-source.tar.gz)
if ! chroot "$ROOT" "$PREPARER" "${ARGS[@]}" --plan > /tmp/prep-plan.log 2>&1; then
  tail -n 100 /tmp/prep-plan.log >&2
  fail 'user preparation plan failed'
fi
if [[ $PREP_EXISTING -eq 0 ]]; then
  [[ ! -e "$ROOT/home/integration/.config/omarchy" && ! -e "$ROOT/home/integration/.config/foot" ]] || fail 'plan mode wrote user configuration'
  [[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" ]] || fail 'plan mode wrote preparation state'
fi

if ! chroot "$ROOT" "$PREPARER" "${ARGS[@]}" --apply > /tmp/prep-apply.log 2>&1; then
  tail -n 120 /tmp/prep-apply.log >&2
  fail 'user preparation apply failed'
fi
if ! chroot "$ROOT" "$PREPARER" "${ARGS[@]}" --apply > /tmp/prep-reapply.log 2>&1; then
  tail -n 120 /tmp/prep-reapply.log >&2
  fail 'user preparation idempotent reapply failed'
fi

HOME_ROOT="$ROOT/home/integration"
EXPECTED_OWNER=$(awk -F ':' '$1 == "integration" {print $3 ":" $4}' "$ROOT/etc/passwd") || fail 'unable to derive target ownership'
cmp -s /repo/config/arm64-overrides/shell.json "$HOME_ROOT/.config/omarchy/shell.json" || fail 'seeded shell configuration differs'
cmp -s "$ROOT/usr/share/omarchy-arm64/config/foot/foot.ini" "$HOME_ROOT/.config/foot/foot.ini" || fail 'seeded Foot configuration differs'
[[ $(stat -c '%u:%g' "$HOME_ROOT/.config/omarchy/shell.json") == "$EXPECTED_OWNER" ]] || fail 'shell seed ownership differs'
[[ $(stat -c '%u:%g' "$HOME_ROOT/.config/foot/foot.ini") == "$EXPECTED_OWNER" ]] || fail 'Foot seed ownership differs'
[[ $(find "$HOME_ROOT/.local/state/omarchy/migrations" -maxdepth 1 -type f -size 0 | wc -l) -eq 87 ]] || fail 'migration baseline marker count differs'
[[ $(readlink "$HOME_ROOT/.local/state/omarchy/current/theme") == '/usr/share/omarchy-arm64/themes/tokyo-night' ]] || fail 'initial theme link differs'
[[ $(readlink "$HOME_ROOT/.local/state/omarchy/current/background") == '/usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp' ]] || fail 'initial background link differs'
STATE="$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration"
grep -Fxq 'target_user=integration' "$STATE" || fail 'preparation target state differs'
grep -Fxq 'historical_migrations_run=no' "$STATE" || fail 'migration execution state differs'
grep -Fxq 'session_modified=no' "$STATE" || fail 'session modification state differs'
grep -Fxq 'activation=no' "$STATE" || fail 'activation state differs'
grep -Fxq 'foot_sha256=a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf' "$STATE" || fail 'Foot digest state differs'

tree_manifest "$ROOT/boot" > /tmp/prep-boot.after || fail 'unable to resnapshot boot tree'
cmp -s /tmp/prep-boot.before /tmp/prep-boot.after || fail 'boot tree changed during user preparation'
for state_name in hardware-selection base-system-packages base-system-selection hyprland-selection omarchy-shell-selection; do
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/$state_name" >> /tmp/prep-layers.after || fail "unable to resnapshot state: $state_name"
done
sha256sum "$ROOT/home/integration/.config/hypr/hyprland.lua" >> /tmp/prep-layers.after || fail 'unable to resnapshot Hyprland config'
cmp -s /tmp/prep-layers.before /tmp/prep-layers.after || fail 'lower-layer state changed during user preparation'
if [[ $PREP_EXISTING -eq 1 ]]; then
  tree_manifest "$ROOT/home/integration/.config" > /tmp/prep-home.after || fail 'unable to resnapshot existing user configuration'
  tree_manifest "$ROOT/home/integration/.local/state/omarchy" >> /tmp/prep-home.after || fail 'unable to resnapshot existing Omarchy state'
  sha256sum "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-integration" >> /tmp/prep-home.after || fail 'unable to resnapshot existing preparation state'
  cmp -s /tmp/prep-home.before /tmp/prep-home.after || fail 'idempotent preparation changed the existing exact seed'
fi
for unit in uwsm-app@.service sddm.service greetd.service; do
  unit_state=$(chroot "$ROOT" systemctl is-enabled "$unit" 2>/dev/null)
  case "$unit_state" in enabled|enabled-runtime|linked|linked-runtime|alias) fail "graphical session unit was enabled: $unit" ;; esac
done

printf '[PASS] native ARM64 user preparation seeded shell, Foot, theme and background\n'
printf '[PASS] all 87 historical migrations became zero-byte markers and none executed\n'
printf '[PASS] idempotent reapply made no conflicting or session changes\n'
printf '[PASS] boot and every lower-layer state/config remained byte-identical\n'
printf '[PASS] retained disposable volume is prepared but session activation remains blocked\n'
