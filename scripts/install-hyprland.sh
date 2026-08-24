#!/usr/bin/env bash

# Install a version-locked, minimal Hyprland validation session into a mounted
# Arch Linux ARM root. This script does not enable a display manager, autologin,
# UWSM, or any Omarchy userland. Plan mode is read-only.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve script directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION="plan"
ACTION_SET=0
ROOT=""
TARGET_USER=""
CHROOT_COMMAND="arch-chroot"
LOCK_FILE="$REPO_ROOT/config/hyprland/packages.lock"
TRANSACTION_LOCK="$REPO_ROOT/config/hyprland/transaction.lock"
PACKAGE_DIR=""
CONFIG_TEMPLATE="$REPO_ROOT/config/hyprland/minimal.lua"
BASE_PACKAGE_LOCK="$REPO_ROOT/config/base-system/packages.lock"
EXPECTED_KERNEL='linux-rpi-16k'
EXPECTED_KERNEL_VERSION='6.18.45-1'
EXPECTED_KERNEL_RELEASE='6.18.45-1-rpi-16k'
EXPECTED_BOARD_COMMIT='bf7a0ab55654c96b74d013520e1196d39f66391a'
EXPECTED_PACKAGES=(
  hyprland aquamarine uwsm
  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk foot
  mesa mesa-utils vulkan-broadcom vulkan-tools libdrm
  libinput evtest pciutils usbutils brightnessctl
  pipewire pipewire-pulse wireplumber polkit xorg-xwayland
)

usage() {
  printf '%s\n' \
    'Usage: install-hyprland.sh --root DIR --user NAME --package-dir DIR ' \
    '  [--plan|--apply] [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify the root, hardware gate, package lock and user (default)' \
    '  --apply                  Mutate only the named offline root' \
    '' \
    'Options:' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --lock-file FILE         Alternate complete direct-package lock' \
    '  --transaction-lock FILE  Alternate content-pinned transaction lock' \
    '  --config-template FILE   Alternate complete config template (tests only)' \
    '  --help                   Show this help' \
    '' \
    'The installer requires the exact hardware and configured-admin states. It' \
    'refuses any --user other than the selected Phase 1 admin and never enables' \
    'autologin, a display manager, UWSM, or an Omarchy service.'
}

set_action() {
  local requested=$1
  if [[ $ACTION_SET -eq 1 && "$ACTION" != "$requested" ]]; then
    install_common_die 'choose exactly one action'
  fi
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --plan) set_action plan; shift ;;
    --apply) set_action apply; shift ;;
    --root)
      (($# >= 2)) || install_common_die '--root requires a directory'
      ROOT=$2
      shift 2
      ;;
    --user)
      (($# >= 2)) || install_common_die '--user requires a name'
      TARGET_USER=$2
      shift 2
      ;;
    --chroot-command)
      (($# >= 2)) || install_common_die '--chroot-command requires a path'
      CHROOT_COMMAND=$2
      shift 2
      ;;
    --lock-file)
      (($# >= 2)) || install_common_die '--lock-file requires a path'
      LOCK_FILE=$2
      shift 2
      ;;
    --transaction-lock)
      (($# >= 2)) || install_common_die '--transaction-lock requires a path'
      TRANSACTION_LOCK=$2
      shift 2
      ;;
    --package-dir)
      (($# >= 2)) || install_common_die '--package-dir requires a directory'
      PACKAGE_DIR=$2
      shift 2
      ;;
    --config-template)
      (($# >= 2)) || install_common_die '--config-template requires a path'
      CONFIG_TEMPLATE=$2
      shift 2
      ;;
    --device|--write-device|--allow-live-root)
      install_common_die "$1 is forbidden; this installer accepts an offline filesystem root only"
      ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ -n "$TARGET_USER" ]] || install_common_die '--user is required'
case "$TARGET_USER" in
  *[!a-zA-Z0-9_-]*|'') install_common_die 'user name contains unsupported characters' ;;
esac

install_common_require_file 'package lock' "$LOCK_FILE"
install_common_require_file 'transaction lock' "$TRANSACTION_LOCK"
install_common_require_file 'Hyprland config template' "$CONFIG_TEMPLATE"
ROOT=$(install_common_require_offline_arch_root "$ROOT")
[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || install_common_die "package directory is missing or a symlink: $PACKAGE_DIR"
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || install_common_die 'unable to resolve package directory'

HARDWARE_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection"
install_common_require_file 'hardware selection state' "$HARDWARE_STATE"
state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$HARDWARE_STATE"
}
[[ "$(state_field kernel_package)" == "$EXPECTED_KERNEL" ]] || install_common_die 'hardware state does not select linux-rpi-16k'
[[ "$(state_field kernel_version)" == "$EXPECTED_KERNEL_VERSION" ]] || install_common_die 'hardware state has an unexpected kernel version'
[[ "$(state_field kernel_release)" == "$EXPECTED_KERNEL_RELEASE" ]] || install_common_die 'hardware state has an unexpected kernel release'
[[ "$(state_field board_source_commit)" == "$EXPECTED_BOARD_COMMIT" ]] || install_common_die 'hardware state has an unaudited board source commit'

BASE_PACKAGE_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages"
BASE_SELECTION_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection"
install_common_require_file 'base-system package lock' "$BASE_PACKAGE_LOCK"
install_common_require_file 'base-system package state' "$BASE_PACKAGE_STATE"
install_common_require_file 'base-system selection state' "$BASE_SELECTION_STATE"
EXPECTED_BASE_PACKAGES=$(awk -F '|' '$0 !~ /^#/ { print $1 "=" $2 }' "$BASE_PACKAGE_LOCK") || install_common_die 'unable to render expected base-system package state'
OBSERVED_BASE_PACKAGES=$(sed -n '1,$p' "$BASE_PACKAGE_STATE") || install_common_die 'unable to read base-system package state'
[[ "$OBSERVED_BASE_PACKAGES" == "$EXPECTED_BASE_PACKAGES" ]] || install_common_die 'base-system package state does not match the exact lock'
base_state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$BASE_SELECTION_STATE"
}
[[ $(awk 'END { print NR }' "$BASE_SELECTION_STATE") -eq 9 ]] || install_common_die 'base-system selection state must contain exactly nine fields'
SELECTED_ADMIN=$(base_state_field admin_user) || install_common_die 'base-system selection lacks one admin user'
[[ "$SELECTED_ADMIN" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$SELECTED_ADMIN" != root ]] || install_common_die 'base-system selected admin is unsafe'
[[ $(base_state_field network_manager) == NetworkManager ]] || install_common_die 'base-system selection does not assign networking to NetworkManager'
[[ "$TARGET_USER" == "$SELECTED_ADMIN" ]] || install_common_die "target user must match the selected Phase 1 admin: $SELECTED_ADMIN"

PASSWD_FILE="$ROOT/etc/passwd"
install_common_require_file 'target passwd database' "$PASSWD_FILE"
USER_RECORD=$(awk -F ':' -v wanted="$TARGET_USER" '$1 == wanted { count++; record=$0 } END { if (count == 1) print record; else exit 1 }' "$PASSWD_FILE") || install_common_die "target user is missing or duplicated: $TARGET_USER"
TARGET_UID=$(printf '%s\n' "$USER_RECORD" | awk -F ':' '{print $3}')
TARGET_GID=$(printf '%s\n' "$USER_RECORD" | awk -F ':' '{print $4}')
TARGET_HOME=$(printf '%s\n' "$USER_RECORD" | awk -F ':' '{print $6}')
case "$TARGET_UID:$TARGET_GID" in *[!0-9:]*) install_common_die 'target user has non-numeric UID/GID' ;; esac
[[ "$TARGET_UID" -gt 0 ]] || install_common_die 'root cannot own the graphical validation session'
[[ "$TARGET_HOME" == "/home/$TARGET_USER" ]] || install_common_die "target home must be /home/$TARGET_USER"
HOME_ROOT="$ROOT$TARGET_HOME"
[[ -d "$HOME_ROOT" && ! -L "$HOME_ROOT" ]] || install_common_die "target home is missing or unsafe: $HOME_ROOT"

LOCK_ROWS=$(awk '$0 !~ /^#/ && NF { count++ } END { print count+0 }' "$LOCK_FILE")
[[ "$LOCK_ROWS" -eq "${#EXPECTED_PACKAGES[@]}" ]] || install_common_die "package lock must contain exactly ${#EXPECTED_PACKAGES[@]} entries"
lock_field() {
  local name=$1
  local index=$2
  awk -F '|' -v wanted="$name" -v field="$index" '$0 !~ /^#/ && $1 == wanted { count++; value=$field } END { if (count == 1 && value != "") print value; else exit 1 }' "$LOCK_FILE"
}
for name in "${EXPECTED_PACKAGES[@]}"; do
  version=$(lock_field "$name" 2) || install_common_die "invalid or duplicate $name lock entry"
  architecture=$(lock_field "$name" 3) || install_common_die "missing $name architecture"
  repository=$(lock_field "$name" 4) || install_common_die "missing $name repository"
  role=$(lock_field "$name" 5) || install_common_die "missing $name role"
  case "$architecture" in aarch64|any) ;; *) install_common_die "unsupported architecture for $name: $architecture" ;; esac
  case "$repository" in core|extra|alarm|aur) ;; *) install_common_die "unsupported repository for $name: $repository" ;; esac
  case "$role" in core|handoff|graphics|diagnostic|input|hardware|audio|session) ;; *) install_common_die "unsupported role for $name: $role" ;; esac
done

if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 9 || $1 == "" || seen_name[$1]++ || seen_file[$8]++) exit 1
    count++
  }
  END { if (count == 0) exit 1 }
' "$TRANSACTION_LOCK"; then
  install_common_die 'transaction lock has invalid fields, duplicates or no entries'
fi

TRANSACTION_NAMES=()
TRANSACTION_VERSIONS=()
TRANSACTION_ARCHITECTURES=()
TRANSACTION_REPOSITORIES=()
TRANSACTION_PATHS=()
TRANSACTION_DIRECT=()
file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then stat -c '%s' "$1"
  else stat -f '%z' "$1"
  fi
}
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || install_common_die "unexpected extra transaction field for $name"
  [[ "$name" =~ ^[a-z0-9@._+-]+$ ]] || install_common_die "unsafe transaction package name: $name"
  [[ "$architecture" == aarch64 || "$architecture" == any ]] || install_common_die "unsupported transaction architecture for $name: $architecture"
  [[ "$repository" == core || "$repository" == extra ]] || install_common_die "unsupported transaction repository for $name: $repository"
  [[ "$kind" == direct || "$kind" == dependency ]] || install_common_die "unsupported transaction kind for $name: $kind"
  [[ "$digest" =~ ^[0-9a-f]{64}$ && "$signature_digest" =~ ^[0-9a-f]{64}$ ]] || install_common_die "invalid transaction digest for $name"
  [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9@._+:-]*\.pkg\.tar\.[A-Za-z0-9]+$ ]] || install_common_die "unsafe transaction filename for $name: $filename"
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || install_common_die "invalid transaction size for $name"
  package_path="$PACKAGE_DIR/$filename"
  signature_path="${package_path}.sig"
  [[ $(file_size "$package_path") == "$size" ]] || install_common_die "transaction package size differs for $name"
  install_common_assert_package_arch "$package_path" "$name" "$version" "$architecture" "$digest"
  install_common_require_file 'detached package signature' "$signature_path"
  [[ $(install_common_sha256 "$signature_path") == "$signature_digest" ]] || install_common_die "detached signature SHA-256 mismatch for $name"
  direct_marker=0
  if [[ "$kind" == direct ]]; then direct_marker=1; fi
  TRANSACTION_NAMES+=("$name")
  TRANSACTION_VERSIONS+=("$version")
  TRANSACTION_ARCHITECTURES+=("$architecture")
  TRANSACTION_REPOSITORIES+=("$repository")
  TRANSACTION_PATHS+=("$package_path")
  TRANSACTION_DIRECT+=("$direct_marker")
done < "$TRANSACTION_LOCK"

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi

package_installed_exact() {
  local name=$1
  local version=$2
  local observed=""
  if ! observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "$name" 2>/dev/null); then
    return 1
  fi
  [[ "$observed" == "$name $version" ]]
}

for name in "${EXPECTED_PACKAGES[@]}"; do
  expected_version=$(lock_field "$name" 2)
  expected_architecture=$(lock_field "$name" 3)
  expected_repository=$(lock_field "$name" 4)
  transaction_matches=0
  for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
    [[ "${TRANSACTION_NAMES[$transaction_index]}" == "$name" ]] || continue
    [[ "${TRANSACTION_DIRECT[$transaction_index]}" -eq 1 ]] || install_common_die "direct package is mislabeled as a dependency: $name"
    [[ "${TRANSACTION_VERSIONS[$transaction_index]}" == "$expected_version" ]] || install_common_die "direct transaction version differs for $name"
    [[ "${TRANSACTION_ARCHITECTURES[$transaction_index]}" == "$expected_architecture" ]] || install_common_die "direct transaction architecture differs for $name"
    [[ "${TRANSACTION_REPOSITORIES[$transaction_index]}" == "$expected_repository" ]] || install_common_die "direct transaction repository differs for $name"
    transaction_matches=$((transaction_matches + 1))
  done
  if [[ $transaction_matches -eq 0 ]]; then
    package_installed_exact "$name" "$expected_version" || install_common_die "direct package is absent from the transaction and not already exact: $name $expected_version"
  elif [[ $transaction_matches -ne 1 ]]; then
    install_common_die "direct package appears more than once in the transaction: $name"
  fi
done

printf '%s\n' \
  '[PASS] offline root           Arch Linux ARM identity, boot tree and pacman database present' \
  "[PASS] hardware gate         $EXPECTED_KERNEL_VERSION ($EXPECTED_KERNEL_RELEASE), board $EXPECTED_BOARD_COMMIT" \
  "[PASS] base-system gate      exact package state; selected admin=$SELECTED_ADMIN" \
  "[PASS] target user           $TARGET_USER uid=$TARGET_UID gid=$TARGET_GID home=$TARGET_HOME" \
  "[PASS] direct package lock   ${#EXPECTED_PACKAGES[@]} packages" \
  "[PASS] offline transaction   ${#TRANSACTION_NAMES[@]} package/signature pairs" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  "Config: $TARGET_HOME/.config/hypr/hyprland.lua" \
  'Session start: start-hyprland from a local TTY' \
  ''

CONFIG_DIR="$HOME_ROOT/.config/hypr"
CONFIG_TARGET="$CONFIG_DIR/hyprland.lua"
if [[ -e "$HOME_ROOT/.config" ]]; then
  [[ -d "$HOME_ROOT/.config" && ! -L "$HOME_ROOT/.config" ]] || install_common_die 'target .config is not a safe directory'
fi
if [[ -e "$CONFIG_DIR" ]]; then
  [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || install_common_die 'target Hyprland config path is not a safe directory'
fi
if [[ -e "$CONFIG_TARGET" ]]; then
  [[ -f "$CONFIG_TARGET" && ! -L "$CONFIG_TARGET" ]] || install_common_die 'target Hyprland config is not a safe regular file'
  cmp -s "$CONFIG_TEMPLATE" "$CONFIG_TARGET" || install_common_die 'existing Hyprland config differs; refusing to overwrite user configuration'
fi

if [[ "$ACTION" == 'plan' ]]; then
  printf '%s\n' \
    'Plan complete. No package, user configuration, service or boot file was changed.' \
    'Every incremental package payload and detached signature is content-pinned; no mirror was contacted.'
  exit 0
fi

[[ -w "$ROOT" && -w "$HOME_ROOT" ]] || install_common_die 'offline root and target home must be writable'

PACKAGES_CURRENT=1
for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
  if ! package_installed_exact "${TRANSACTION_NAMES[$transaction_index]}" "${TRANSACTION_VERSIONS[$transaction_index]}"; then
    PACKAGES_CURRENT=0
  fi
done

if [[ $PACKAGES_CURRENT -eq 1 ]]; then
  printf '[PASS] package transaction already current; skipping reinstall\n'
else
  mkdir -p "$ROOT/var/cache/pacman/pkg" || install_common_fail 'unable to create target package cache'
  TARGET_PACKAGES=()
  for package_path in "${TRANSACTION_PATHS[@]}"; do
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
  if ! "$CHROOT_COMMAND" "$ROOT" pacman -U --needed --noconfirm "${TARGET_PACKAGES[@]}"; then
    install_common_fail 'Hyprland package transaction failed; no user config was written'
  fi
fi

for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
  package_installed_exact "${TRANSACTION_NAMES[$transaction_index]}" "${TRANSACTION_VERSIONS[$transaction_index]}" || install_common_fail "post-install transaction package mismatch: ${TRANSACTION_NAMES[$transaction_index]} ${TRANSACTION_VERSIONS[$transaction_index]}"
done
for name in "${EXPECTED_PACKAGES[@]}"; do
  expected_version=$(lock_field "$name" 2)
  package_installed_exact "$name" "$expected_version" || install_common_fail "post-install package mismatch: $name $expected_version"
done

CREATED_DOT_CONFIG=0
CREATED_HYPR_DIR=0
if [[ ! -d "$HOME_ROOT/.config" ]]; then
  mkdir "$HOME_ROOT/.config" || install_common_fail 'unable to create target .config directory'
  CREATED_DOT_CONFIG=1
fi
if [[ ! -d "$CONFIG_DIR" ]]; then
  mkdir "$CONFIG_DIR" || install_common_fail 'unable to create target Hyprland config directory'
  CREATED_HYPR_DIR=1
fi
if [[ ! -e "$CONFIG_TARGET" ]]; then
  install -m 0644 "$CONFIG_TEMPLATE" "$CONFIG_TARGET" || install_common_fail 'unable to install minimal Hyprland config'
fi
if [[ $CREATED_DOT_CONFIG -eq 1 ]]; then
  chown "$TARGET_UID:$TARGET_GID" "$HOME_ROOT/.config" || install_common_fail 'unable to set .config ownership'
fi
if [[ $CREATED_HYPR_DIR -eq 1 ]]; then
  chown "$TARGET_UID:$TARGET_GID" "$CONFIG_DIR" || install_common_fail 'unable to set Hyprland directory ownership'
fi
chown "$TARGET_UID:$TARGET_GID" "$CONFIG_TARGET" || install_common_fail 'unable to set Hyprland config ownership'

STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/hyprland-selection"
STATE_TMP="$STATE_DIR/.hyprland-selection.$$"
LOCK_SHA=$(install_common_sha256 "$LOCK_FILE") || install_common_fail 'unable to hash package lock'
TRANSACTION_LOCK_SHA=$(install_common_sha256 "$TRANSACTION_LOCK") || install_common_fail 'unable to hash transaction lock'
CONFIG_SHA=$(install_common_sha256 "$CONFIG_TEMPLATE") || install_common_fail 'unable to hash config template'
{
  printf 'hyprland_version=%s\n' "$(lock_field hyprland 2)"
  printf 'package_lock_sha256=%s\n' "$LOCK_SHA"
  printf 'transaction_lock_sha256=%s\n' "$TRANSACTION_LOCK_SHA"
  printf 'transaction_packages=%s\n' "${#TRANSACTION_NAMES[@]}"
  printf 'config_sha256=%s\n' "$CONFIG_SHA"
  printf 'target_user=%s\n' "$TARGET_USER"
  printf 'session_start=start-hyprland\n'
  printf 'uwsm_enabled=no\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage Hyprland selection state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set Hyprland state permissions'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish Hyprland selection state'

printf '%s\n' \
  '[PASS] direct packages        all locked versions are installed' \
  "[PASS] minimal config        $TARGET_HOME/.config/hypr/hyprland.lua sha256=$CONFIG_SHA" \
  '[PASS] session policy        no autologin, display manager or UWSM activation' \
  '[PASS] Hyprland state        /var/lib/uconsole-omarchy-arm64/hyprland-selection' \
  '' \
  'Hyprland layer staged in the offline root.' \
  'After Phase 1 passes on hardware, log in at a TTY and run: start-hyprland' \
  'Then run: scripts/validate-system.sh --phase hyprland'
