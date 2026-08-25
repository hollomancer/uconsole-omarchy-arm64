#!/usr/bin/env bash

# Install the exact offline NetworkManager/sudo/Bluetooth closure needed for
# first boot. Repository resolution and network access are intentionally absent.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve script directory\n' >&2
  exit 2
fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION=plan
ACTION_SET=0
ROOT=''
PACKAGE_DIR=''
CHROOT_COMMAND=arch-chroot
LOCK_FILE="$REPO_ROOT/config/base-system/packages.lock"
EXPECTED_KERNEL=linux-rpi-16k
EXPECTED_KERNEL_VERSION=6.18.45-1
EXPECTED_KERNEL_RELEASE=6.18.45-1-rpi-16k
EXPECTED_BOARD_COMMIT=bf7a0ab55654c96b74d013520e1196d39f66391a

usage() {
  printf '%s\n' \
    'Usage: install-base-system-packages.sh --root DIR --package-dir DIR [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify exact inputs and print transaction (default)' \
    '  --apply                  Install locked packages in the offline root' \
    '' \
    'Options:' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --lock-file FILE         Alternate complete lock (tests/version bumps)' \
    '  --help                   Show this help' \
    '' \
    'No mirror is contacted. Hardware state, local package bytes and direct' \
    'post-install dependencies must match exactly.'
}

set_action() {
  local requested=$1
  if [[ $ACTION_SET -eq 1 && "$ACTION" != "$requested" ]]; then install_common_die 'choose exactly one action'; fi
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --plan) set_action plan; shift ;;
    --apply) set_action apply; shift ;;
    --root) (($# >= 2)) || install_common_die '--root requires a directory'; ROOT=$2; shift 2 ;;
    --package-dir) (($# >= 2)) || install_common_die '--package-dir requires a directory'; PACKAGE_DIR=$2; shift 2 ;;
    --chroot-command) (($# >= 2)) || install_common_die '--chroot-command requires a path'; CHROOT_COMMAND=$2; shift 2 ;;
    --lock-file) (($# >= 2)) || install_common_die '--lock-file requires a file'; LOCK_FILE=$2; shift 2 ;;
    --device|--write-device|--allow-live-root) install_common_die "$1 is forbidden; this installer accepts an offline root only" ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
HARDWARE_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection"
install_common_require_file 'hardware selection state' "$HARDWARE_STATE"
state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$HARDWARE_STATE"
}
[[ $(state_field kernel_package) == "$EXPECTED_KERNEL" ]] || install_common_die 'hardware state does not select linux-rpi-16k'
[[ $(state_field kernel_version) == "$EXPECTED_KERNEL_VERSION" ]] || install_common_die 'hardware state has an unexpected kernel version'
[[ $(state_field kernel_release) == "$EXPECTED_KERNEL_RELEASE" ]] || install_common_die 'hardware state has an unexpected kernel release'
[[ $(state_field board_source_commit) == "$EXPECTED_BOARD_COMMIT" ]] || install_common_die 'hardware state has an unaudited board source commit'

[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || install_common_die "package directory is missing or a symlink: $PACKAGE_DIR"
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || install_common_die 'unable to resolve package directory'
install_common_require_file 'base-system package lock' "$LOCK_FILE"
if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 5 || $1 == "" || seen[$1]++) exit 1
    count++
  }
  END { if (count == 0) exit 1 }
' "$LOCK_FILE"; then
  install_common_die 'base-system lock has an invalid field count, duplicate name or no entries'
fi

PACKAGE_NAMES=()
PACKAGE_VERSIONS=()
PACKAGE_PATHS=()
while IFS='|' read -r name version architecture digest filename extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || install_common_die "unexpected extra lock field for $name"
  [[ "$name" =~ ^[a-z0-9@._+-]+$ ]] || install_common_die "unsafe package name in lock: $name"
  [[ "$architecture" == aarch64 || "$architecture" == any ]] || install_common_die "unsupported package architecture in lock: $architecture"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || install_common_die "invalid package digest in lock: $name"
  [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9@._+:-]*\.pkg\.tar\.[A-Za-z0-9]+$ ]] || install_common_die "unsafe package filename in lock: $filename"
  package_path="$PACKAGE_DIR/$filename"
  install_common_assert_package_arch "$package_path" "$name" "$version" "$architecture" "$digest"
  PACKAGE_NAMES+=("$name")
  PACKAGE_VERSIONS+=("$version")
  PACKAGE_PATHS+=("$package_path")
done < "$LOCK_FILE"

for required_name in networkmanager sudo bluez bluez-utils; do
  REQUIRED_COUNT=0
  for observed_name in "${PACKAGE_NAMES[@]}"; do
    [[ "$observed_name" == "$required_name" ]] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
  done
  [[ $REQUIRED_COUNT -eq 1 ]] || install_common_die "lock must contain exactly one $required_name package"
done

printf '%s\n' \
  '[PASS] hardware gate          exact selected kernel/board state present' \
  "[PASS] locked closure        ${#PACKAGE_NAMES[@]} content-pinned local packages" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  'Required services: NetworkManager, sshd, systemd-resolved, bluetooth' \
  'Packages:'
for package_index in "${!PACKAGE_NAMES[@]}"; do
  printf '  %s %s\n' "${PACKAGE_NAMES[$package_index]}" "${PACKAGE_VERSIONS[$package_index]}"
done
printf '\n'

if [[ "$ACTION" == plan ]]; then
  printf '%s\n' \
    'Plan complete. No package cache, database, service or policy file was changed.' \
    'Apply performs one local pacman -U transaction and never resolves a mirror.'
  exit 0
fi

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi
[[ -w "$ROOT" ]] || install_common_die "offline root must be writable: $ROOT"
mkdir -p "$ROOT/var/cache/pacman/pkg" || install_common_fail 'unable to create target package cache'

TARGET_PACKAGES=()
for package_path in "${PACKAGE_PATHS[@]}"; do
  filename=${package_path##*/}
  destination="$ROOT/var/cache/pacman/pkg/$filename"
  if [[ -e "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || install_common_die "unsafe package cache entry: $destination"
    cmp -s "$package_path" "$destination" || install_common_die "package cache entry differs: $destination"
  else
    install -m 0644 "$package_path" "$destination" || install_common_fail "unable to stage package: $filename"
  fi
  TARGET_PACKAGES+=("/var/cache/pacman/pkg/$filename")
done

ALL_CURRENT=1
for package_index in "${!PACKAGE_NAMES[@]}"; do
  observed=''
  if ! observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "${PACKAGE_NAMES[$package_index]}" 2>/dev/null); then
    ALL_CURRENT=0
    continue
  fi
  [[ "$observed" == "${PACKAGE_NAMES[$package_index]} ${PACKAGE_VERSIONS[$package_index]}" ]] || ALL_CURRENT=0
done
if [[ $ALL_CURRENT -eq 1 ]]; then
  printf '[PASS] package transaction already current; skipping reinstall\n'
else
  "$CHROOT_COMMAND" "$ROOT" pacman -U --needed --noconfirm "${TARGET_PACKAGES[@]}" || install_common_fail 'offline base-system package transaction failed'
fi

for package_index in "${!PACKAGE_NAMES[@]}"; do
  observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "${PACKAGE_NAMES[$package_index]}") || install_common_fail "installed package query failed: ${PACKAGE_NAMES[$package_index]}"
  [[ "$observed" == "${PACKAGE_NAMES[$package_index]} ${PACKAGE_VERSIONS[$package_index]}" ]] || install_common_fail "installed package differs: $observed"
done
MISSING=''
if ! MISSING=$("$CHROOT_COMMAND" "$ROOT" pacman -T networkmanager sudo bluez bluez-utils 2>&1); then
  install_common_fail "base-system direct dependencies remain unsatisfied: $MISSING"
fi

STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/base-system-packages"
STATE_TMP="$STATE_DIR/.base-system-packages.$$"
mkdir -p "$STATE_DIR" || install_common_fail 'unable to create base-system state directory'
{
  for package_index in "${!PACKAGE_NAMES[@]}"; do
    printf '%s=%s\n' "${PACKAGE_NAMES[$package_index]}" "${PACKAGE_VERSIONS[$package_index]}"
  done
} > "$STATE_TMP" || install_common_fail 'unable to stage base-system package state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set base-system package state mode'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish base-system package state'

printf '%s\n' \
  '[PASS] package transaction   exact offline closure installed' \
  '[PASS] dependency check      NetworkManager, sudo and BlueZ satisfied' \
  '[PASS] selection state       /var/lib/uconsole-omarchy-arm64/base-system-packages' \
  'No mirror, service policy or physical device was opened.'
