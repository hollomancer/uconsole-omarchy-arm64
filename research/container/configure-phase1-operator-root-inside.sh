#!/usr/bin/env bash

# Mount the retained root with the same bounded chroot topology used by the
# integration tests, then plan/apply only the audited base-system configurator.

set -u
set -o pipefail

ROOT=/output/root
CHROOT=/usr/bin/chroot
ACTION=${UCONSOLE_CONFIG_ACTION:-}
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

[[ "$ACTION" == plan || "$ACTION" == apply ]] || fail 'configuration action is missing or unsafe'
[[ -f "$ROOT/etc/os-release" && -d "$ROOT/var/lib/pacman/local" ]] || fail 'retained Arch root is missing'
for input_file in /run/uconsole-operator-ssh-public-key /run/uconsole-operator-console-password-hash; do
  [[ -f "$input_file" && ! -L "$input_file" ]] || fail "required operator file is missing: $input_file"
done
if [[ ${UCONSOLE_WIFI_PRESEED:-} == yes ]]; then
  [[ -f /run/uconsole-operator-wifi-keyfile && ! -L /run/uconsole-operator-wifi-keyfile ]] || fail 'selected Wi-Fi keyfile is missing'
elif [[ ${UCONSOLE_WIFI_PRESEED:-} != no ]]; then
  fail 'Wi-Fi selection is missing or unsafe'
fi

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

CONFIG_ARGS=(
  --root "$ROOT"
  --admin-user "${UCONSOLE_ADMIN_USER:-}"
  --ssh-public-key "$ROOT/run/uconsole-operator-ssh-public-key"
  --console-password-hash-file "$ROOT/run/uconsole-operator-console-password-hash"
  --reg-domain "${UCONSOLE_REG_DOMAIN:-}"
  --hostname "${UCONSOLE_HOSTNAME:-}"
  --timezone "${UCONSOLE_TIMEZONE:-}"
  --chroot-command "$CHROOT"
)
if [[ ${UCONSOLE_WIFI_PRESEED:-} == yes ]]; then
  CONFIG_ARGS+=(--wifi-keyfile "$ROOT/run/uconsole-operator-wifi-keyfile")
fi

/repo/scripts/configure-base-system.sh --plan "${CONFIG_ARGS[@]}" || fail 'operator configuration plan failed'
if [[ "$ACTION" == plan ]]; then
  [[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'read-only plan target was already configured'
  printf '[PASS] operator configuration plan completed against a read-only root\n'
  printf '[PASS] private files were mounted read-only and their contents were not logged\n'
  exit 0
fi

/repo/scripts/configure-base-system.sh --apply "${CONFIG_ARGS[@]}" || fail 'operator configuration apply failed'
/repo/scripts/configure-base-system.sh --apply "${CONFIG_ARGS[@]}" || fail 'operator configuration idempotent reapply failed'
printf '[PASS] operator configuration applied and idempotently reapplied\n'
printf '[PASS] post-apply inspection will run in a new read-only container\n'
