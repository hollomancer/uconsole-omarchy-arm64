#!/usr/bin/env bash

# Install the selected CM5 hardware layer into a mounted, offline Arch Linux
# ARM root. Plan mode is read-only. Apply mode installs content-pinned packages
# through the target's pacman/DKMS hooks and activates a small boot include only
# after the modules and overlays are verified.

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
KERNEL_VARIANT=""
KERNEL_PACKAGE=""
HEADERS_PACKAGE=""
BOARD_PACKAGE=""
CHROOT_COMMAND="arch-chroot"
LOCK_FILE="$REPO_ROOT/config/uconsole-hardware/packages.lock"

KERNEL_NAME='linux-rpi-16k'
HEADERS_NAME='linux-rpi-16k-headers'
BOARD_NAME='uconsole-cm5-dkms'
BOOT_FRAGMENT="$REPO_ROOT/config/uconsole-hardware/config.txt.fragment"
BLOCK_BEGIN='# BEGIN uconsole-omarchy-arm64 hardware include'
BLOCK_END='# END uconsole-omarchy-arm64 hardware include'
EXPECTED_BLOCK="$BLOCK_BEGIN
include uconsole-cm5.txt
$BLOCK_END"

usage() {
  printf '%s\n' \
    'Usage: install-uconsole-hardware.sh --root DIR --kernel linux-rpi-16k \' \
    '  --kernel-package FILE --headers-package FILE --board-package FILE \' \
    '  [--plan|--apply] [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify inputs and print the transaction (default)' \
    '  --apply                  Mutate only the named offline root' \
    '' \
    'Options:' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --lock-file FILE         Alternate complete content lock (version bumps/tests)' \
    '  --help                   Show this help' \
    '' \
    'The live root, symlink roots, /dev paths, physical devices, and unpinned' \
    'packages are rejected. No Omarchy files are installed by this script.'
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
    --plan)
      set_action plan
      shift
      ;;
    --apply)
      set_action apply
      shift
      ;;
    --root)
      (($# >= 2)) || install_common_die '--root requires a directory'
      ROOT=$2
      shift 2
      ;;
    --kernel)
      (($# >= 2)) || install_common_die '--kernel requires a value'
      KERNEL_VARIANT=$2
      shift 2
      ;;
    --kernel-package)
      (($# >= 2)) || install_common_die '--kernel-package requires a file'
      KERNEL_PACKAGE=$2
      shift 2
      ;;
    --headers-package)
      (($# >= 2)) || install_common_die '--headers-package requires a file'
      HEADERS_PACKAGE=$2
      shift 2
      ;;
    --board-package)
      (($# >= 2)) || install_common_die '--board-package requires a file'
      BOARD_PACKAGE=$2
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
    --device|--write-device|--allow-live-root)
      install_common_die "$1 is forbidden; this installer accepts an offline filesystem root only"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      install_common_die "unknown option: $1"
      ;;
  esac
done

[[ "$KERNEL_VARIANT" == "$KERNEL_NAME" ]] || install_common_die "--kernel must be the selected baseline: $KERNEL_NAME"
[[ -n "$KERNEL_PACKAGE" ]] || install_common_die '--kernel-package is required'
[[ -n "$HEADERS_PACKAGE" ]] || install_common_die '--headers-package is required'
[[ -n "$BOARD_PACKAGE" ]] || install_common_die '--board-package is required'

install_common_require_file 'package lock' "$LOCK_FILE"
lock_field() {
  local name=$1
  local index=$2
  awk -F '|' -v wanted="$name" -v field="$index" '
    $0 !~ /^#/ && $1 == wanted { count++; value=$field }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$LOCK_FILE"
}

KERNEL_VERSION=$(lock_field "$KERNEL_NAME" 2) || install_common_die "invalid or duplicate $KERNEL_NAME lock entry"
KERNEL_SHA256=$(lock_field "$KERNEL_NAME" 3) || install_common_die "missing $KERNEL_NAME SHA-256"
KERNEL_RELEASE=$(lock_field "$KERNEL_NAME" 4) || install_common_die "missing $KERNEL_NAME release"
HEADERS_VERSION=$(lock_field "$HEADERS_NAME" 2) || install_common_die "invalid or duplicate $HEADERS_NAME lock entry"
HEADERS_SHA256=$(lock_field "$HEADERS_NAME" 3) || install_common_die "missing $HEADERS_NAME SHA-256"
HEADERS_RELEASE=$(lock_field "$HEADERS_NAME" 4) || install_common_die "missing $HEADERS_NAME release"
BOARD_VERSION=$(lock_field "$BOARD_NAME" 2) || install_common_die "invalid or duplicate $BOARD_NAME lock entry"
BOARD_SHA256=$(lock_field "$BOARD_NAME" 3) || install_common_die "missing $BOARD_NAME SHA-256"
BOARD_SOURCE_COMMIT=$(lock_field "$BOARD_NAME" 4) || install_common_die "missing $BOARD_NAME source commit"

[[ "$HEADERS_RELEASE" == "$KERNEL_RELEASE" ]] || install_common_die 'kernel and header releases differ in the package lock'
for digest in "$KERNEL_SHA256" "$HEADERS_SHA256" "$BOARD_SHA256"; do
  [[ ${#digest} -eq 64 ]] || install_common_die 'package lock contains a non-SHA256 digest length'
  case "$digest" in *[!0-9a-f]*) install_common_die 'package lock contains a non-hexadecimal SHA-256' ;; esac
done
[[ "$KERNEL_RELEASE" == *-rpi-16k ]] || install_common_die "package lock is not a 16K Pi kernel release: $KERNEL_RELEASE"
[[ "$BOARD_SOURCE_COMMIT" == bf7a0ab55654c96b74d013520e1196d39f66391a ]] || install_common_die 'package lock advances the unaudited board source commit'

ROOT=$(install_common_require_offline_arch_root "$ROOT")
install_common_require_file 'boot fragment' "$BOOT_FRAGMENT"
install_common_assert_package "$KERNEL_PACKAGE" "$KERNEL_NAME" "$KERNEL_VERSION" "$KERNEL_SHA256"
install_common_assert_package "$HEADERS_PACKAGE" "$HEADERS_NAME" "$HEADERS_VERSION" "$HEADERS_SHA256"
install_common_assert_package "$BOARD_PACKAGE" "$BOARD_NAME" "$BOARD_VERSION" "$BOARD_SHA256"

CONFIG_TXT="$ROOT/boot/config.txt"
[[ -f "$CONFIG_TXT" && ! -L "$CONFIG_TXT" ]] || install_common_die "missing regular boot configuration: $CONFIG_TXT"

if grep -Eq '^[[:space:]]*dtparam[[:space:]]*=[[:space:]]*spi[[:space:]]*=[[:space:]]*on([[:space:]]|$)' "$CONFIG_TXT"; then
  install_common_die 'active dtparam=spi=on conflicts with the panel reset GPIO; resolve it explicitly'
fi
if grep -Eq '^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*audremap-pi5([,[:space:]]|$)' "$CONFIG_TXT"; then
  install_common_die 'active audremap-pi5 conflicts with the uConsole audio overlay; resolve it explicitly'
fi

BOOT_INCLUDE="$ROOT/boot/uconsole-cm5.txt"
if [[ -e "$BOOT_INCLUDE" ]]; then
  [[ -f "$BOOT_INCLUDE" && ! -L "$BOOT_INCLUDE" ]] || install_common_die "unsafe existing boot include: $BOOT_INCLUDE"
  cmp -s "$BOOT_FRAGMENT" "$BOOT_INCLUDE" || install_common_die 'existing uconsole-cm5.txt differs from the pinned fragment'
fi

BEGIN_COUNT=$(grep -Fxc "$BLOCK_BEGIN" "$CONFIG_TXT")
END_COUNT=$(grep -Fxc "$BLOCK_END" "$CONFIG_TXT")
if [[ $BEGIN_COUNT -eq 0 && $END_COUNT -eq 0 ]]; then
  if grep -Eq '^[[:space:]]*include[[:space:]]+uconsole-cm5\.txt[[:space:]]*$' "$CONFIG_TXT"; then
    install_common_die 'unmanaged uconsole-cm5.txt include already exists'
  fi
elif [[ $BEGIN_COUNT -eq 1 && $END_COUNT -eq 1 ]]; then
  OBSERVED_BLOCK=$(awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    $0 == begin { capture=1 }
    capture { print }
    $0 == end { capture=0 }
  ' "$CONFIG_TXT")
  [[ "$OBSERVED_BLOCK" == "$EXPECTED_BLOCK" ]] || install_common_die 'managed hardware include block differs from the expected block'
else
  install_common_die 'boot configuration has incomplete or duplicate managed markers'
fi

printf '%s\n' \
  '[PASS] offline root           Arch Linux ARM identity, boot tree and pacman database present' \
  '[PASS] boot conflicts         no active SPI or audremap-pi5 conflict' \
  "[PASS] selected baseline     $KERNEL_NAME $KERNEL_VERSION ($KERNEL_RELEASE)" \
  "[PASS] board source          $BOARD_SOURCE_COMMIT" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  'Package transaction:' \
  "  $KERNEL_NAME $KERNEL_VERSION" \
  "  $HEADERS_NAME $HEADERS_VERSION" \
  "  $BOARD_NAME $BOARD_VERSION" \
  'Boot activation:' \
  '  /boot/uconsole-cm5.txt' \
  '  managed include in /boot/config.txt' \
  ''

if [[ "$ACTION" == 'plan' ]]; then
  printf '%s\n' \
    'Plan complete. No package database, module tree, or boot file was changed.' \
    'Apply prerequisites inside the target: dkms, gcc, make, and a functioning' \
    'aarch64 arch-chroot/binfmt environment.'
  exit 0
fi

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi
[[ -w "$ROOT" && -w "$ROOT/boot" ]] || install_common_die "offline root and boot directory must be writable: $ROOT"
mkdir -p "$ROOT/var/cache/pacman/pkg" || install_common_fail 'unable to create target package cache'

MISSING_DEPS=""
if ! MISSING_DEPS=$("$CHROOT_COMMAND" "$ROOT" pacman -T dkms gcc make 2>&1); then
  install_common_fail "target prerequisites are missing; install a pinned dependency set first: $MISSING_DEPS"
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

stage_package() {
  local source=$1
  local basename=${source##*/}
  local destination="$ROOT/var/cache/pacman/pkg/$basename"
  case "$basename" in
    *[!A-Za-z0-9._+-]*) install_common_die "unsafe package basename: $basename" ;;
  esac
  if [[ -e "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || install_common_die "unsafe package cache entry: $destination"
    cmp -s "$source" "$destination" || install_common_die "package cache entry differs: $destination"
  else
    install -m 0644 "$source" "$destination" || install_common_fail "unable to stage package: $basename"
  fi
  printf '%s\n' "/var/cache/pacman/pkg/$basename"
}

PACKAGES_CURRENT=0
if package_installed_exact "$KERNEL_NAME" "$KERNEL_VERSION" && \
   package_installed_exact "$HEADERS_NAME" "$HEADERS_VERSION" && \
   package_installed_exact "$BOARD_NAME" "$BOARD_VERSION"; then
  PACKAGES_CURRENT=1
  printf '[PASS] package transaction already current; skipping reinstall\n'
fi

if [[ $PACKAGES_CURRENT -eq 0 ]]; then
  TARGET_KERNEL=$(stage_package "$KERNEL_PACKAGE")
  TARGET_HEADERS=$(stage_package "$HEADERS_PACKAGE")
  TARGET_BOARD=$(stage_package "$BOARD_PACKAGE")

  REMOVE_PACKAGES=()
  for obsolete in linux-aarch64 linux-aarch64-headers uboot-raspberrypi; do
    if "$CHROOT_COMMAND" "$ROOT" pacman -Q "$obsolete" >/dev/null 2>&1; then
      REMOVE_PACKAGES+=("$obsolete")
    fi
  done
  if ((${#REMOVE_PACKAGES[@]} > 0)); then
    printf 'Removing conflicting generic boot packages:'
    printf ' %s' "${REMOVE_PACKAGES[@]}"
    printf '\n'
    if ! "$CHROOT_COMMAND" "$ROOT" pacman -Rdd --noconfirm "${REMOVE_PACKAGES[@]}"; then
      install_common_fail 'failed to remove conflicting generic boot packages'
    fi
  fi

  if ! "$CHROOT_COMMAND" "$ROOT" pacman -U --noconfirm "$TARGET_KERNEL" "$TARGET_HEADERS" "$TARGET_BOARD"; then
    install_common_fail 'hardware package transaction failed; boot include was not activated'
  fi
fi

if ! "$CHROOT_COMMAND" "$ROOT" mkinitcpio -k "$KERNEL_RELEASE" -g /boot/initramfs-linux.img -S autodetect; then
  install_common_fail 'broad first-boot linux-rpi-16k initramfs rebuild failed; boot include was not activated'
fi
[[ -s "$ROOT/boot/initramfs-linux.img" ]] || install_common_fail 'broad first-boot initramfs rebuild produced no image; boot include was not activated'

DKMS_STATUS=""
if ! DKMS_STATUS=$("$CHROOT_COMMAND" "$ROOT" dkms status -m uconsole-cm5 -v 0.1 -k "$KERNEL_RELEASE" 2>&1); then
  install_common_fail "DKMS status failed; boot include was not activated: $DKMS_STATUS"
fi
if [[ "$DKMS_STATUS" != *uconsole-cm5* || "$DKMS_STATUS" != *"$KERNEL_RELEASE"* || "$DKMS_STATUS" != *installed* ]]; then
  install_common_fail "DKMS modules are not installed for $KERNEL_RELEASE: $DKMS_STATUS"
fi

for required in \
  "$ROOT/boot/overlays/uconsole-cm5-base.dtbo" \
  "$ROOT/boot/overlays/uconsole-audio-cm5.dtbo" \
  "$ROOT/usr/src/uconsole-cm5-0.1/dkms.conf"; do
  [[ -s "$required" ]] || install_common_fail "installed hardware artifact is missing or empty: $required"
done

if [[ ! -e "$BOOT_INCLUDE" ]]; then
  install -m 0644 "$BOOT_FRAGMENT" "$BOOT_INCLUDE" || install_common_fail 'unable to install boot include'
fi
if [[ $BEGIN_COUNT -eq 0 ]]; then
  BACKUP="$ROOT/boot/config.txt.pre-uconsole"
  if [[ ! -e "$BACKUP" ]]; then
    cp -p -- "$CONFIG_TXT" "$BACKUP" || install_common_fail 'unable to back up config.txt'
  fi
  printf '\n%s\n' "$EXPECTED_BLOCK" >> "$CONFIG_TXT" || install_common_fail 'unable to activate the boot include'
fi

STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
mkdir -p "$STATE_DIR" || install_common_fail 'unable to create hardware state directory'
STATE_FILE="$STATE_DIR/hardware-selection"
STATE_TMP="$STATE_DIR/.hardware-selection.$$"
{
  printf 'kernel_package=%s\n' "$KERNEL_NAME"
  printf 'kernel_version=%s\n' "$KERNEL_VERSION"
  printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
  printf 'board_package=%s\n' "$BOARD_NAME"
  printf 'board_version=%s\n' "$BOARD_VERSION"
  printf 'board_source_commit=%s\n' "$BOARD_SOURCE_COMMIT"
  printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
  printf 'headers_sha256=%s\n' "$HEADERS_SHA256"
  printf 'board_sha256=%s\n' "$BOARD_SHA256"
} > "$STATE_TMP" || install_common_fail 'unable to stage hardware selection state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set hardware state permissions'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish hardware selection state'

CONFIG_SHA=$(install_common_sha256 "$CONFIG_TXT") || install_common_fail 'unable to hash config.txt'
INCLUDE_SHA=$(install_common_sha256 "$BOOT_INCLUDE") || install_common_fail 'unable to hash boot include'
printf '%s\n' \
  "[PASS] DKMS                  $DKMS_STATUS" \
  '[PASS] overlays              both package-owned overlays are present' \
  "[PASS] boot configuration   config.txt=$CONFIG_SHA include=$INCLUDE_SHA" \
  '[PASS] hardware state        /var/lib/uconsole-omarchy-arm64/hardware-selection' \
  '' \
  'Hardware layer installed in the offline root. No physical device was opened.' \
  'Do not install Hyprland until scripts/validate-system.sh --phase hardware passes on the CM5.'
