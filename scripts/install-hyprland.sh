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
CONFIG_TEMPLATE="$REPO_ROOT/config/hyprland/minimal.lua"
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
    'Usage: install-hyprland.sh --root DIR --user NAME [--plan|--apply] [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify the root, hardware gate, package lock and user (default)' \
    '  --apply                  Mutate only the named offline root' \
    '' \
    'Options:' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --lock-file FILE         Alternate complete direct-package lock' \
    '  --config-template FILE   Alternate complete config template (tests only)' \
    '  --help                   Show this help' \
    '' \
    'The installer requires the exact selected hardware state. It never enables' \
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
install_common_require_file 'Hyprland config template' "$CONFIG_TEMPLATE"
ROOT=$(install_common_require_offline_arch_root "$ROOT")

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

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi

printf '%s\n' \
  '[PASS] offline root           Arch Linux ARM identity, boot tree and pacman database present' \
  "[PASS] hardware gate         $EXPECTED_KERNEL_VERSION ($EXPECTED_KERNEL_RELEASE), board $EXPECTED_BOARD_COMMIT" \
  "[PASS] target user           $TARGET_USER uid=$TARGET_UID gid=$TARGET_GID home=$TARGET_HOME" \
  "[PASS] direct package lock   ${#EXPECTED_PACKAGES[@]} packages" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  "Config: $TARGET_HOME/.config/hypr/hyprland.lua" \
  'Session start: start-hyprland from a local TTY' \
  ''

for name in "${EXPECTED_PACKAGES[@]}"; do
  expected_version=$(lock_field "$name" 2)
  expected_architecture=$(lock_field "$name" 3)
  expected_repository=$(lock_field "$name" 4)
  PACKAGE_INFO=""
  if ! PACKAGE_INFO=$("$CHROOT_COMMAND" "$ROOT" pacman --color never -Si "$name" 2>&1); then
    install_common_fail "locked package is unavailable from target sync databases: $name: $PACKAGE_INFO"
  fi
  observed_version=$(printf '%s\n' "$PACKAGE_INFO" | awk '/^Version[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  observed_architecture=$(printf '%s\n' "$PACKAGE_INFO" | awk '/^Architecture[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  observed_repository=$(printf '%s\n' "$PACKAGE_INFO" | awk '/^Repository[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  [[ "$observed_version" == "$expected_version" ]] || install_common_fail "$name repository version moved: expected $expected_version, observed ${observed_version:-unknown}"
  [[ "$observed_architecture" == "$expected_architecture" ]] || install_common_fail "$name architecture differs: expected $expected_architecture, observed ${observed_architecture:-unknown}"
  [[ "$observed_repository" == "$expected_repository" ]] || install_common_fail "$name repository differs: expected $expected_repository, observed ${observed_repository:-unknown}"
done
printf '[PASS] repository preflight   every locked direct version is currently resolvable\n'

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
    'The direct package lock is exact; transitive versions and payload hashes are not yet frozen.'
  exit 0
fi

[[ -w "$ROOT" && -w "$HOME_ROOT" ]] || install_common_die 'offline root and target home must be writable'

package_installed_exact() {
  local name=$1
  local version=$2
  local observed=""
  if ! observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "$name" 2>/dev/null); then
    return 1
  fi
  [[ "$observed" == "$name $version" ]]
}

PACKAGES_CURRENT=1
for name in "${EXPECTED_PACKAGES[@]}"; do
  expected_version=$(lock_field "$name" 2)
  if ! package_installed_exact "$name" "$expected_version"; then
    PACKAGES_CURRENT=0
  fi
done

if [[ $PACKAGES_CURRENT -eq 1 ]]; then
  printf '[PASS] package transaction already current; skipping reinstall\n'
else
  if ! "$CHROOT_COMMAND" "$ROOT" pacman -S --needed --noconfirm "${EXPECTED_PACKAGES[@]}"; then
    install_common_fail 'Hyprland package transaction failed; no user config was written'
  fi
fi

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
CONFIG_SHA=$(install_common_sha256 "$CONFIG_TEMPLATE") || install_common_fail 'unable to hash config template'
{
  printf 'hyprland_version=%s\n' "$(lock_field hyprland 2)"
  printf 'package_lock_sha256=%s\n' "$LOCK_SHA"
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
