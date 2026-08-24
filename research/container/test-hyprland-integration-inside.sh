#!/usr/bin/env bash

# Native-aarch64 integration for the exact minimal Hyprland transaction.

set -u
set -o pipefail

SOURCE_ROOT=/source/root
ROOT=/output/root
CHROOT=/usr/bin/chroot
ROOT_MOUNTED=0
DEV_MOUNTED=0
PROC_MOUNTED=0
SYS_MOUNTED=0
RUN_MOUNTED=0
PACKAGE_DIR_MOUNTED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $PACKAGE_DIR_MOUNTED -eq 1 ]]; then umount -R "$ROOT/run/uconsole-hyprland-packages" || status=1; fi
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

[[ -f "$SOURCE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'configured Phase 1 source root is missing'
[[ ! -e "$SOURCE_ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || fail 'source already has a Hyprland transaction'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'destination Linux volume must be empty'
mkdir "$ROOT" || fail 'unable to create destination root'
bsdtar -cpf - --acls --xattrs --no-fflags --numeric-owner -C "$SOURCE_ROOT" . | \
  bsdtar -xpf - --acls --xattrs --no-fflags --numeric-owner -C "$ROOT"
COPY_STATUS=(${PIPESTATUS[@]})
[[ ${COPY_STATUS[0]} -eq 0 && ${COPY_STATUS[1]} -eq 0 ]] || fail "root clone failed: create=${COPY_STATUS[0]} extract=${COPY_STATUS[1]}"

mount --bind "$ROOT" "$ROOT" || fail 'unable to make destination root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make destination root private'
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

# The transaction is already a read-only container bind. Build a tiny
# package-only tmpfs view from individual read-only bind mounts so Pacman
# consumes payloads directly without duplicating them or discovering adjacent
# detached signatures. Those signatures were verified by the resolver; the
# installer independently verifies every payload digest before this point.
mkdir "$ROOT/run/uconsole-hyprland-packages" || fail 'unable to create in-root package mount point'
mount -t tmpfs -o size=2m,nodev,nosuid,noexec tmpfs "$ROOT/run/uconsole-hyprland-packages" || fail 'unable to mount package-only tmpfs view'
PACKAGE_DIR_MOUNTED=1
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" && -f "/packages/$filename" ]] || fail "invalid or missing package-view input: $name"
  : > "$ROOT/run/uconsole-hyprland-packages/$filename" || fail "unable to create package-view mount point: $filename"
  mount --bind "/packages/$filename" "$ROOT/run/uconsole-hyprland-packages/$filename" || fail "unable to bind package payload: $filename"
  mount -o remount,bind,ro "$ROOT/run/uconsole-hyprland-packages/$filename" || fail "unable to make package payload read-only: $filename"
  : "$version" "$architecture" "$repository" "$kind" "$digest" "$signature_digest" "$size"
done < /repo/config/hyprland/transaction.lock

INSTALL_ARGS=(
  --root "$ROOT"
  --user integration
  --package-dir /packages
  --package-dir-in-root /run/uconsole-hyprland-packages
  --chroot-command "$CHROOT"
)
if ! /repo/scripts/install-hyprland.sh --plan "${INSTALL_ARGS[@]}" > /tmp/hyprland-plan.log 2>&1; then
  tail -n 80 /tmp/hyprland-plan.log >&2
  fail 'Hyprland plan failed'
fi
[[ ! -e "$ROOT/home/integration/.config/hypr" ]] || fail 'plan mode created Hyprland user configuration'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || fail 'plan mode created Hyprland state'

if ! /repo/scripts/install-hyprland.sh --apply "${INSTALL_ARGS[@]}" > /tmp/hyprland-apply.log 2>&1; then
  tail -n 80 /tmp/hyprland-apply.log >&2
  fail 'Hyprland apply failed'
fi
if ! /repo/scripts/install-hyprland.sh --apply "${INSTALL_ARGS[@]}" > /tmp/hyprland-reapply.log 2>&1; then
  tail -n 80 /tmp/hyprland-reapply.log >&2
  fail 'Hyprland idempotent reapply failed'
fi

TRANSACTION_COUNT=0
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid transaction row: $name"
  [[ $("$CHROOT" "$ROOT" pacman -Q "$name") == "$name $version" ]] || fail "installed transaction package differs: $name"
  TRANSACTION_COUNT=$((TRANSACTION_COUNT + 1))
  : "$architecture" "$repository" "$kind" "$digest" "$signature_digest" "$filename" "$size"
done < /repo/config/hyprland/transaction.lock
[[ $TRANSACTION_COUNT -eq 204 ]] || fail "Hyprland transaction count differs: $TRANSACTION_COUNT"

DIRECT_COUNT=0
while IFS='|' read -r name version architecture repository role extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid direct-package row: $name"
  [[ $("$CHROOT" "$ROOT" pacman -Q "$name") == "$name $version" ]] || fail "installed direct package differs: $name"
  DIRECT_COUNT=$((DIRECT_COUNT + 1))
  : "$architecture" "$repository" "$role"
done < /repo/config/hyprland/packages.lock
[[ $DIRECT_COUNT -eq 21 ]] || fail "direct-package count differs: $DIRECT_COUNT"

CONFIG="$ROOT/home/integration/.config/hypr/hyprland.lua"
cmp -s /repo/config/hyprland/minimal.lua "$CONFIG" || fail 'installed Hyprland configuration differs'
EXPECTED_OWNER=$(awk -F ':' '$1 == "integration" { print $3 ":" $4 }' "$ROOT/etc/passwd") || fail 'unable to read integration account ownership'
[[ $(stat -c '%u:%g' "$CONFIG") == "$EXPECTED_OWNER" ]] || fail 'Hyprland configuration ownership differs'
STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection"
[[ $(awk 'END { print NR }' "$STATE") -eq 8 ]] || fail 'Hyprland state field count differs'
grep -Fqx 'hyprland_version=0.56.1-3' "$STATE" || fail 'Hyprland version state differs'
grep -Fqx 'transaction_packages=204' "$STATE" || fail 'Hyprland transaction count state differs'
grep -Fqx 'target_user=integration' "$STATE" || fail 'Hyprland target-user state differs'
grep -Fqx 'session_start=start-hyprland' "$STATE" || fail 'Hyprland session-start state differs'
grep -Fqx 'uwsm_enabled=no' "$STATE" || fail 'Hyprland UWSM state differs'
grep -Fqx "package_lock_sha256=$(sha256sum /repo/config/hyprland/packages.lock | awk '{print $1}')" "$STATE" || fail 'Hyprland direct-lock state differs'
grep -Fqx "transaction_lock_sha256=$(sha256sum /repo/config/hyprland/transaction.lock | awk '{print $1}')" "$STATE" || fail 'Hyprland transaction-lock state differs'
grep -Fqx "config_sha256=$(sha256sum /repo/config/hyprland/minimal.lua | awk '{print $1}')" "$STATE" || fail 'Hyprland config state differs'

for unit in uwsm-app@.service sddm.service greetd.service; do
  "$CHROOT" "$ROOT" systemctl is-enabled "$unit" >/dev/null 2>&1
  UNIT_STATUS=$?
  ((UNIT_STATUS != 0)) || fail "graphical session unit was enabled: $unit"
done
[[ -x "$ROOT/usr/bin/start-hyprland" ]] || fail 'manual Hyprland launcher is missing'
[[ ! -e "$ROOT/usr/bin/omarchy-shell" && ! -e "$ROOT/usr/share/omarchy-arm64" ]] || fail 'Omarchy entered the Phase 2 root'
[[ ! -e "$SOURCE_ROOT/home/integration/.config/hypr" ]] || fail 'read-only source acquired a Hyprland config'
[[ ! -e "$SOURCE_ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || fail 'read-only source acquired Hyprland state'

printf '[PASS] native ARM64 Hyprland transaction installed packages=%s direct=%s\n' "$TRANSACTION_COUNT" "$DIRECT_COUNT"
printf '[PASS] minimal config and exact state survived idempotent reapply\n'
printf '[PASS] no display manager, autologin, UWSM or Omarchy activation was introduced\n'
printf '[PASS] source configured root remained unchanged; retained destination is ready for shell-runtime resolution\n'
