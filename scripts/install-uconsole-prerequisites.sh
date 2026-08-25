#!/usr/bin/env bash

# Install the exact offline compiler/DKMS closure needed by the selected
# uConsole hardware package. No repository resolution or network is used.

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
LOCK_FILE="$REPO_ROOT/config/uconsole-hardware/prerequisites.lock"

usage() {
  printf '%s\n' \
    'Usage: install-uconsole-prerequisites.sh --root DIR --package-dir DIR [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify exact inputs and print transaction (default)' \
    '  --apply                  Install the locked local packages in the offline root' \
    '' \
    'Options:' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --lock-file FILE         Alternate complete lock (tests/version bumps)' \
    '  --help                   Show this help' \
    '' \
    'No mirror is contacted. Live roots, devices and unlocked packages are rejected.'
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
[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || install_common_die "package directory is missing or a symlink: $PACKAGE_DIR"
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || install_common_die 'unable to resolve package directory'
install_common_require_file 'prerequisite lock' "$LOCK_FILE"
if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 5 || $1 == "" || seen[$1]++) exit 1
    count++
  }
  END { if (count == 0) exit 1 }
' "$LOCK_FILE"; then
  install_common_die 'prerequisite lock has an invalid field count, duplicate name or no entries'
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

printf '%s\n' \
  '[PASS] offline root           Arch Linux ARM identity and pacman database present' \
  "[PASS] locked closure        ${#PACKAGE_NAMES[@]} content-pinned local packages" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  'Packages:'
for package_index in "${!PACKAGE_NAMES[@]}"; do
  printf '  %s %s\n' "${PACKAGE_NAMES[$package_index]}" "${PACKAGE_VERSIONS[$package_index]}"
done
printf '\n'

if [[ "$ACTION" == plan ]]; then
  printf '%s\n' \
    'Plan complete. No package cache, database, root file or boot file was changed.' \
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
  "$CHROOT_COMMAND" "$ROOT" pacman -U --needed --noconfirm "${TARGET_PACKAGES[@]}" || install_common_fail 'offline prerequisite package transaction failed'
fi

for package_index in "${!PACKAGE_NAMES[@]}"; do
  observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "${PACKAGE_NAMES[$package_index]}") || install_common_fail "installed package query failed: ${PACKAGE_NAMES[$package_index]}"
  [[ "$observed" == "${PACKAGE_NAMES[$package_index]} ${PACKAGE_VERSIONS[$package_index]}" ]] || install_common_fail "installed package differs: $observed"
done
MISSING=''
if ! MISSING=$("$CHROOT_COMMAND" "$ROOT" pacman -T dkms gcc make 2>&1); then
  install_common_fail "hardware build prerequisites remain unsatisfied: $MISSING"
fi

STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/build-prerequisites-selection"
STATE_TMP="$STATE_DIR/.build-prerequisites-selection.$$"
mkdir -p "$STATE_DIR" || install_common_fail 'unable to create prerequisite state directory'
{
  for package_index in "${!PACKAGE_NAMES[@]}"; do
    printf '%s=%s\n' "${PACKAGE_NAMES[$package_index]}" "${PACKAGE_VERSIONS[$package_index]}"
  done
} > "$STATE_TMP" || install_common_fail 'unable to stage prerequisite state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set prerequisite state mode'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish prerequisite state'

printf '%s\n' \
  '[PASS] package transaction   exact offline closure installed' \
  '[PASS] dependency check      dkms, gcc and make satisfied' \
  '[PASS] selection state       /var/lib/uconsole-omarchy-arm64/build-prerequisites-selection' \
  'No mirror or physical device was opened.'
