#!/usr/bin/env bash

# Install the content-locked official Omarchy shell runtime plus the reviewed
# thin local userland package into an offline exact Hyprland root. This does not
# seed a home directory, start a session, enable UWSM, or touch hardware/boot.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve script directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION='plan'
ACTION_SET=0
ROOT=''
TARGET_USER=''
PACKAGE_DIR=''
PACKAGE_DIR_IN_ROOT=''
USERLAND_PACKAGE=''
USERLAND_PACKAGE_IN_ROOT=''
CHROOT_COMMAND='arch-chroot'
DIRECT_LOCK="$REPO_ROOT/config/omarchy-shell/packages.lock"
TRANSACTION_LOCK="$REPO_ROOT/config/omarchy-shell/transaction.lock"
USERLAND_LOCK="$REPO_ROOT/config/omarchy-shell/userland.lock"
RUNTIME_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-runtime-command-policy.tsv"
EXPECTED_DIRECT_LOCK_SHA='019a79e470a26a7b3c34adb5209f02269eca3cb4df78e70a15aa41619f097159'
EXPECTED_TRANSACTION_LOCK_SHA='9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3'
EXPECTED_USERLAND_LOCK_SHA='837b81b7c29e83b09cce5da831d4907691cf93d98c0be2b16d8f77be55529008'
EXPECTED_RUNTIME_POLICY_SHA='5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d'
EXPECTED_HYPRLAND_VERSION='0.56.1-3'
EXPECTED_DIRECT_COUNT=10
EXPECTED_TRANSACTION_COUNT=24
EXPECTED_RUNTIME_COUNT=54

usage() {
  printf '%s\n' \
    'Usage: install-omarchy-shell.sh --root DIR --user NAME --package-dir DIR' \
    '  --userland-package FILE [--plan|--apply] [options]' \
    '' \
    'Options:' \
    '  --chroot-command PATH          arch-chroot-compatible command' \
    '  --package-dir-in-root DIR      reviewed package-only bind below /run/uconsole-*' \
    '  --userland-package-in-root FILE reviewed local-package bind below that directory' \
    '  --direct-lock FILE             alternate direct lock (tests only)' \
    '  --transaction-lock FILE        alternate transaction lock (tests only)' \
    '  --userland-lock FILE           alternate local package lock (tests only)' \
    '  --runtime-policy FILE          alternate runtime policy (tests only)' \
    '' \
    'No mirror is contacted. No home, session, service enablement, update path,' \
    'kernel, firmware, device tree, initramfs, bootloader, or /boot file is changed.'
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
    --user) (($# >= 2)) || install_common_die '--user requires a name'; TARGET_USER=$2; shift 2 ;;
    --package-dir) (($# >= 2)) || install_common_die '--package-dir requires a directory'; PACKAGE_DIR=$2; shift 2 ;;
    --package-dir-in-root) (($# >= 2)) || install_common_die '--package-dir-in-root requires a directory'; PACKAGE_DIR_IN_ROOT=$2; shift 2 ;;
    --userland-package) (($# >= 2)) || install_common_die '--userland-package requires a file'; USERLAND_PACKAGE=$2; shift 2 ;;
    --userland-package-in-root) (($# >= 2)) || install_common_die '--userland-package-in-root requires a file'; USERLAND_PACKAGE_IN_ROOT=$2; shift 2 ;;
    --chroot-command) (($# >= 2)) || install_common_die '--chroot-command requires a path'; CHROOT_COMMAND=$2; shift 2 ;;
    --direct-lock) (($# >= 2)) || install_common_die '--direct-lock requires a file'; DIRECT_LOCK=$2; shift 2 ;;
    --transaction-lock) (($# >= 2)) || install_common_die '--transaction-lock requires a file'; TRANSACTION_LOCK=$2; shift 2 ;;
    --userland-lock) (($# >= 2)) || install_common_die '--userland-lock requires a file'; USERLAND_LOCK=$2; shift 2 ;;
    --runtime-policy) (($# >= 2)) || install_common_die '--runtime-policy requires a file'; RUNTIME_POLICY=$2; shift 2 ;;
    --activate|--enable-uwsm|--enable-display-manager|--run-migrations|--allow-live-root|--device|--write-device|--force)
      install_common_die "$1 is forbidden by the offline shell boundary"
      ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$TARGET_USER" != root ]] || install_common_die '--user must be a safe non-root account name'
for required in "$DIRECT_LOCK" "$TRANSACTION_LOCK" "$USERLAND_LOCK" "$RUNTIME_POLICY" "$USERLAND_PACKAGE"; do
  install_common_require_file 'locked Omarchy shell input' "$required"
done
[[ "$(install_common_sha256 "$DIRECT_LOCK")" == "$EXPECTED_DIRECT_LOCK_SHA" ]] || install_common_die 'direct package lock SHA-256 mismatch'
[[ "$(install_common_sha256 "$TRANSACTION_LOCK")" == "$EXPECTED_TRANSACTION_LOCK_SHA" ]] || install_common_die 'transaction lock SHA-256 mismatch'
[[ "$(install_common_sha256 "$USERLAND_LOCK")" == "$EXPECTED_USERLAND_LOCK_SHA" ]] || install_common_die 'userland lock SHA-256 mismatch'
[[ "$(install_common_sha256 "$RUNTIME_POLICY")" == "$EXPECTED_RUNTIME_POLICY_SHA" ]] || install_common_die 'runtime command policy SHA-256 mismatch'

ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || install_common_die "package directory is missing or a symlink: $PACKAGE_DIR"
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || install_common_die 'unable to resolve package directory'
if [[ -n "$PACKAGE_DIR_IN_ROOT" ]]; then
  [[ "$PACKAGE_DIR_IN_ROOT" =~ ^/run/uconsole-[a-z0-9][a-z0-9._-]*$ ]] || install_common_die '--package-dir-in-root must be a dedicated /run/uconsole-* directory'
  [[ -d "$ROOT$PACKAGE_DIR_IN_ROOT" && ! -L "$ROOT$PACKAGE_DIR_IN_ROOT" ]] || install_common_die 'package directory inside the offline root is missing or unsafe'
  [[ "$USERLAND_PACKAGE_IN_ROOT" == "$PACKAGE_DIR_IN_ROOT/"* ]] || install_common_die '--userland-package-in-root must be a file below --package-dir-in-root'
else
  [[ -z "$USERLAND_PACKAGE_IN_ROOT" ]] || install_common_die '--userland-package-in-root requires --package-dir-in-root'
fi

HYPRLAND_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection"
install_common_require_file 'Hyprland selection state' "$HYPRLAND_STATE"
state_field() {
  local file=$1
  local key=$2
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$file"
}
[[ "$(state_field "$HYPRLAND_STATE" hyprland_version)" == "$EXPECTED_HYPRLAND_VERSION" ]] || install_common_die 'Hyprland state version differs'
[[ "$(state_field "$HYPRLAND_STATE" target_user)" == "$TARGET_USER" ]] || install_common_die 'Hyprland state belongs to a different user'
[[ "$(state_field "$HYPRLAND_STATE" uwsm_enabled)" == 'no' ]] || install_common_die 'UWSM was enabled before the shell transaction'

PASSWD_FILE="$ROOT/etc/passwd"
install_common_require_file 'target passwd database' "$PASSWD_FILE"
USER_RECORD=$(awk -F ':' -v wanted="$TARGET_USER" '$1 == wanted { count++; record=$0 } END { if (count == 1) print record; else exit 1 }' "$PASSWD_FILE") || install_common_die "target user is missing or duplicated: $TARGET_USER"
TARGET_HOME=$(printf '%s\n' "$USER_RECORD" | awk -F ':' '{print $6}')
[[ "$TARGET_HOME" == "/home/$TARGET_USER" ]] || install_common_die "target home must be /home/$TARGET_USER"
[[ -d "$ROOT$TARGET_HOME" && ! -L "$ROOT$TARGET_HOME" ]] || install_common_die 'target home is missing or unsafe'

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi
command -v bsdtar >/dev/null 2>&1 || install_common_die 'bsdtar is required to inspect package ownership'

file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then stat -c '%s' "$1"
  else stat -f '%z' "$1"
  fi
}

assert_no_forbidden_payload() {
  local package=$1
  local label=$2
  local listing=''
  listing=$(bsdtar -tf "$package") || install_common_die "unable to list package payload: $label"
  if awk '
    { path=$0; sub(/^\.\//, "", path) }
    path ~ /^(boot|efi)(\/|$)/ || path ~ /^usr\/lib\/(modules|firmware)(\/|$)/ ||
      path ~ /^etc\/(mkinitcpio|kernel)(\/|$)/ { found=1 }
    END { exit !found }
  ' <<< "$listing"; then
    install_common_die "package owns a boot, firmware, kernel, or initramfs path: $label"
  fi
}

DIRECT_NAMES=()
DIRECT_VERSIONS=()
while IFS='|' read -r name version architecture repository role extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" && "$name" =~ ^[a-z0-9@+._-]+$ && "$version" != '' ]] || install_common_die "invalid direct lock row: $name"
  [[ "$architecture" == aarch64 || "$architecture" == any ]] || install_common_die "invalid direct package architecture: $name"
  [[ "$repository" == extra ]] || install_common_die "invalid direct package repository: $name"
  [[ "$role" == shell-runtime || "$role" == power-runtime || "$role" == plugin-registry || "$role" == visual-font ]] || install_common_die "invalid direct package role: $name"
  DIRECT_NAMES+=("$name")
  DIRECT_VERSIONS+=("$version")
done < "$DIRECT_LOCK"
[[ ${#DIRECT_NAMES[@]} -eq $EXPECTED_DIRECT_COUNT ]] || install_common_die "direct package count differs: ${#DIRECT_NAMES[@]}"

if ! awk -F '|' '$0 !~ /^#/ && NF { if (NF != 9 || seen_name[$1]++ || seen_file[$8]++) exit 1; count++ } END { exit !(count == 24) }' "$TRANSACTION_LOCK"; then
  install_common_die 'transaction lock fields, uniqueness, or count differ'
fi

TRANSACTION_NAMES=()
TRANSACTION_VERSIONS=()
TRANSACTION_PATHS=()
TRANSACTION_CHROOT_PATHS=()
TRANSACTION_KINDS=()
while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" && "$name" =~ ^[a-z0-9@+._-]+$ ]] || install_common_die "invalid transaction package name: $name"
  case "$name" in linux|linux-*|linux-rpi*|linux-firmware*|raspberrypi-*|uconsole-*|mkinitcpio*|limine*|grub*|uboot*) install_common_die "hardware or boot package entered the Omarchy shell transaction: $name" ;; esac
  [[ "$architecture" == aarch64 || "$architecture" == any ]] || install_common_die "invalid transaction architecture: $name"
  [[ "$repository" == core || "$repository" == extra ]] || install_common_die "invalid transaction repository: $name"
  [[ "$kind" == direct || "$kind" == dependency ]] || install_common_die "invalid transaction kind: $name"
  [[ "$digest" =~ ^[0-9a-f]{64}$ && "$signature_digest" =~ ^[0-9a-f]{64}$ ]] || install_common_die "invalid transaction digest: $name"
  [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9@._+:-]*\.pkg\.tar\.[A-Za-z0-9]+$ ]] || install_common_die "unsafe transaction filename: $filename"
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || install_common_die "invalid transaction size: $name"
  package_path="$PACKAGE_DIR/$filename"
  signature_path="${package_path}.sig"
  [[ "$(file_size "$package_path")" == "$size" ]] || install_common_die "transaction package size differs: $name"
  install_common_assert_package_arch "$package_path" "$name" "$version" "$architecture" "$digest"
  install_common_require_file 'detached package signature' "$signature_path"
  [[ "$(install_common_sha256 "$signature_path")" == "$signature_digest" ]] || install_common_die "detached signature SHA-256 mismatch: $name"
  assert_no_forbidden_payload "$package_path" "$name"
  TRANSACTION_NAMES+=("$name")
  TRANSACTION_VERSIONS+=("$version")
  TRANSACTION_PATHS+=("$package_path")
  TRANSACTION_KINDS+=("$kind")
  if [[ -n "$PACKAGE_DIR_IN_ROOT" ]]; then
    in_root_package="$ROOT$PACKAGE_DIR_IN_ROOT/$filename"
    [[ -f "$in_root_package" && ! -L "$in_root_package" ]] || install_common_die "mounted in-root package is missing or unsafe: $filename"
    cmp -s "$package_path" "$in_root_package" || install_common_die "mounted in-root package differs from verified host payload: $filename"
    TRANSACTION_CHROOT_PATHS+=("$PACKAGE_DIR_IN_ROOT/$filename")
  else
    TRANSACTION_CHROOT_PATHS+=("")
  fi
done < "$TRANSACTION_LOCK"
[[ ${#TRANSACTION_NAMES[@]} -eq $EXPECTED_TRANSACTION_COUNT ]] || install_common_die 'transaction package count differs'

for direct_index in "${!DIRECT_NAMES[@]}"; do
  direct_name=${DIRECT_NAMES[$direct_index]}
  direct_version=${DIRECT_VERSIONS[$direct_index]}
  matches=0
  for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
    [[ "${TRANSACTION_NAMES[$transaction_index]}" == "$direct_name" ]] || continue
    [[ "${TRANSACTION_VERSIONS[$transaction_index]}" == "$direct_version" && "${TRANSACTION_KINDS[$transaction_index]}" == direct ]] || install_common_die "direct transaction row differs: $direct_name"
    matches=$((matches + 1))
  done
  [[ $matches -eq 1 ]] || install_common_die "direct package does not appear exactly once in the transaction: $direct_name"
done

USERLAND_ROWS=$(awk '$0 !~ /^#/ && NF {n++} END {print n+0}' "$USERLAND_LOCK")
[[ "$USERLAND_ROWS" -eq 1 ]] || install_common_die 'userland lock must contain exactly one package'
IFS='|' read -r USERLAND_NAME USERLAND_VERSION USERLAND_ARCH USERLAND_SHA USERLAND_FILENAME USERLAND_SIZE USERLAND_COMMIT USERLAND_EXTRA < <(awk '$0 !~ /^#/ && NF {print; exit}' "$USERLAND_LOCK")
[[ -z "${USERLAND_EXTRA:-}" && "$USERLAND_NAME" == omarchy-arm64-userland && "$USERLAND_ARCH" == any ]] || install_common_die 'invalid userland lock row'
[[ "$USERLAND_SHA" =~ ^[0-9a-f]{64}$ && "$USERLAND_SIZE" =~ ^[1-9][0-9]*$ && "$USERLAND_COMMIT" =~ ^[0-9a-f]{40}$ ]] || install_common_die 'invalid userland lock values'
[[ "${USERLAND_PACKAGE##*/}" == "$USERLAND_FILENAME" ]] || install_common_die 'local userland package filename differs from lock'
[[ "$(file_size "$USERLAND_PACKAGE")" == "$USERLAND_SIZE" ]] || install_common_die 'local userland package size differs from lock'
install_common_assert_package_arch "$USERLAND_PACKAGE" "$USERLAND_NAME" "$USERLAND_VERSION" "$USERLAND_ARCH" "$USERLAND_SHA"
assert_no_forbidden_payload "$USERLAND_PACKAGE" "$USERLAND_NAME"
if [[ -n "$USERLAND_PACKAGE_IN_ROOT" ]]; then
  in_root_userland="$ROOT$USERLAND_PACKAGE_IN_ROOT"
  [[ -f "$in_root_userland" && ! -L "$in_root_userland" ]] || install_common_die 'mounted in-root userland package is missing or unsafe'
  cmp -s "$USERLAND_PACKAGE" "$in_root_userland" || install_common_die 'mounted in-root userland package differs from verified host payload'
fi

RUNTIME_ROWS=$(awk -F '|' '$0 !~ /^#/ && NF { if (NF != 4 || seen[$1]++ || ($3 != "required-existing" && $3 != "required-shell" && $3 != "inactive-optional")) exit 2; n++ } END {print n+0}' "$RUNTIME_POLICY") || install_common_die 'runtime policy is invalid'
[[ "$RUNTIME_ROWS" -eq $EXPECTED_RUNTIME_COUNT ]] || install_common_die 'runtime policy command count differs'

package_query() {
  "$CHROOT_COMMAND" "$ROOT" pacman -Q "$1" 2>/dev/null
}
package_installed_exact() {
  local observed=''
  observed=$(package_query "$1") || return 1
  [[ "$observed" == "$1 $2" ]]
}
PLANNED_UPGRADES=0
for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
  if observed=$(package_query "${TRANSACTION_NAMES[$transaction_index]}"); then
    expected="${TRANSACTION_NAMES[$transaction_index]} ${TRANSACTION_VERSIONS[$transaction_index]}"
    if [[ "$observed" != "$expected" ]]; then
      observed_version=${observed#* }
      comparison=$("$CHROOT_COMMAND" "$ROOT" vercmp "$observed_version" "${TRANSACTION_VERSIONS[$transaction_index]}") || install_common_die "unable to compare installed package version: $observed"
      [[ "$comparison" =~ ^-?[0-9]+$ ]] || install_common_die "invalid version comparison for installed package: $observed"
      ((comparison < 0)) || install_common_die "refusing implicit package downgrade from installed version: $observed"
      PLANNED_UPGRADES=$((PLANNED_UPGRADES + 1))
    fi
  fi
done
if observed=$(package_query "$USERLAND_NAME"); then
  [[ "$observed" == "$USERLAND_NAME $USERLAND_VERSION" ]] || install_common_die "installed local userland version conflicts with lock: $observed"
fi

STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/omarchy-shell-selection"
if [[ -e "$STATE_FILE" ]]; then
  install_common_require_file 'Omarchy shell state' "$STATE_FILE"
  [[ $(awk 'END {print NR}' "$STATE_FILE") -eq 14 ]] || install_common_die 'existing Omarchy shell state field count differs'
  grep -Fxq "userland_version=$USERLAND_VERSION" "$STATE_FILE" || install_common_die 'existing Omarchy shell state version differs'
  grep -Fxq "userland_sha256=$USERLAND_SHA" "$STATE_FILE" || install_common_die 'existing Omarchy shell state package digest differs'
  grep -Fxq "upstream_commit=$USERLAND_COMMIT" "$STATE_FILE" || install_common_die 'existing Omarchy shell state upstream commit differs'
  grep -Fxq "direct_lock_sha256=$EXPECTED_DIRECT_LOCK_SHA" "$STATE_FILE" || install_common_die 'existing Omarchy shell state direct lock differs'
  grep -Fxq "transaction_lock_sha256=$EXPECTED_TRANSACTION_LOCK_SHA" "$STATE_FILE" || install_common_die 'existing Omarchy shell state transaction differs'
  grep -Fxq "transaction_packages=$EXPECTED_TRANSACTION_COUNT" "$STATE_FILE" || install_common_die 'existing Omarchy shell state transaction count differs'
  grep -Fxq "runtime_policy_sha256=$EXPECTED_RUNTIME_POLICY_SHA" "$STATE_FILE" || install_common_die 'existing Omarchy shell state runtime policy differs'
  grep -Fxq 'runtime_commands=51' "$STATE_FILE" || install_common_die 'existing Omarchy shell state runtime count differs'
  grep -Fxq "target_user=$TARGET_USER" "$STATE_FILE" || install_common_die 'existing Omarchy shell state belongs to another user'
  grep -Fxq 'home_seeded=no' "$STATE_FILE" || install_common_die 'existing Omarchy shell state reports a home seed'
  grep -Fxq 'session_activated=no' "$STATE_FILE" || install_common_die 'existing Omarchy shell state reports activation'
  grep -Fxq 'uwsm_enabled=no' "$STATE_FILE" || install_common_die 'existing Omarchy shell state reports UWSM activation'
  grep -Fxq 'hardware_owned=no' "$STATE_FILE" || install_common_die 'existing Omarchy shell state reports hardware ownership'
  grep -Fxq 'updates_owned=no' "$STATE_FILE" || install_common_die 'existing Omarchy shell state reports update ownership'
fi

printf '%s\n' \
  '[PASS] offline root          exact Arch Linux ARM Hyprland layer' \
  "[PASS] target user          $TARGET_USER home=$TARGET_HOME" \
  "[PASS] official transaction ${#TRANSACTION_NAMES[@]} package/signature pairs; direct=${#DIRECT_NAMES[@]}" \
  "[PASS] local userland       $USERLAND_VERSION any sha256=$USERLAND_SHA" \
  "[PASS] runtime policy       commands=$RUNTIME_ROWS inherited=44 inactive=3" \
  "[PASS] version direction    forward dependency upgrades=$PLANNED_UPGRADES implicit-downgrades=0" \
  '[PASS] ownership boundary   no hardware, boot, update, home, session, or migration payload' \
  '' \
  "Action: $ACTION" \
  'Home seed: no' \
  'Session activation: no'

if [[ "$ACTION" == plan ]]; then
  printf '%s\n' \
    'Plan complete. No package, home, service, session, update, hardware or boot file was changed.' \
    'Every official payload/signature and the local userland package are content-pinned; no mirror was contacted.'
  exit 0
fi

[[ -w "$ROOT" && -w "$STATE_DIR" ]] || install_common_die 'offline root and project state directory must be writable'
PACKAGES_CURRENT=1
for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
  package_installed_exact "${TRANSACTION_NAMES[$transaction_index]}" "${TRANSACTION_VERSIONS[$transaction_index]}" || PACKAGES_CURRENT=0
done
package_installed_exact "$USERLAND_NAME" "$USERLAND_VERSION" || PACKAGES_CURRENT=0

if [[ $PACKAGES_CURRENT -eq 1 ]]; then
  printf '[PASS] shell package transaction already current; skipping reinstall\n'
else
  TARGET_PACKAGES=()
  if [[ -n "$PACKAGE_DIR_IN_ROOT" ]]; then
    TARGET_PACKAGES=("${TRANSACTION_CHROOT_PATHS[@]}" "$USERLAND_PACKAGE_IN_ROOT")
  else
    mkdir -p "$ROOT/var/cache/pacman/pkg" || install_common_fail 'unable to create target package cache'
    for package_path in "${TRANSACTION_PATHS[@]}" "$USERLAND_PACKAGE"; do
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
  fi
  if ! "$CHROOT_COMMAND" "$ROOT" pacman -U --needed --noconfirm "${TARGET_PACKAGES[@]}"; then
    install_common_fail 'Omarchy shell package transaction failed; no home or selection state was written'
  fi
fi

for transaction_index in "${!TRANSACTION_NAMES[@]}"; do
  package_installed_exact "${TRANSACTION_NAMES[$transaction_index]}" "${TRANSACTION_VERSIONS[$transaction_index]}" || install_common_fail "post-install package mismatch: ${TRANSACTION_NAMES[$transaction_index]}"
done
package_installed_exact "$USERLAND_NAME" "$USERLAND_VERSION" || install_common_fail 'post-install local userland mismatch'

REQUIRED_COMMANDS=0
while IFS='|' read -r command_name provider disposition reason extra; do
  [[ -n "$command_name" && "$command_name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || install_common_fail "invalid runtime row after install: $command_name"
  [[ "$disposition" != inactive-optional ]] || continue
  package_query "$provider" >/dev/null || install_common_fail "runtime provider package is absent: $provider"
  if ! "$CHROOT_COMMAND" "$ROOT" /usr/bin/bash --noprofile --norc -c "command -v -- '$command_name' >/dev/null"; then
    install_common_fail "required runtime command is absent: $command_name"
  fi
  REQUIRED_COMMANDS=$((REQUIRED_COMMANDS + 1))
  : "$reason"
done < "$RUNTIME_POLICY"
[[ $REQUIRED_COMMANDS -eq 51 ]] || install_common_fail "required runtime command count differs: $REQUIRED_COMMANDS"

[[ -x "$ROOT/usr/bin/omarchy-launch-shell" && -x "$ROOT/usr/bin/omarchy-shell" && -x "$ROOT/usr/bin/omarchy-menu" ]] || install_common_fail 'reviewed public wrappers are missing'
[[ -f "$ROOT/usr/share/fonts/omarchy/omarchy.ttf" ]] || install_common_fail 'Omarchy icon font is missing'
MONOSPACE_FAMILY=$("$CHROOT_COMMAND" "$ROOT" fc-match -f '%{family[0]}\n' monospace) || install_common_fail 'fontconfig monospace validation failed'
[[ "$MONOSPACE_FAMILY" == 'JetBrainsMono Nerd Font' ]] || install_common_fail "monospace family differs: $MONOSPACE_FAMILY"

for unit in uwsm-app@.service sddm.service greetd.service; do
  unit_state=$("$CHROOT_COMMAND" "$ROOT" systemctl is-enabled "$unit" 2>/dev/null)
  case "$unit_state" in enabled|enabled-runtime|linked|linked-runtime|alias) install_common_fail "graphical session unit was activated: $unit ($unit_state)" ;; esac
done

STATE_TMP="$STATE_DIR/.omarchy-shell-selection.$$"
{
  printf 'userland_version=%s\n' "$USERLAND_VERSION"
  printf 'userland_sha256=%s\n' "$USERLAND_SHA"
  printf 'upstream_commit=%s\n' "$USERLAND_COMMIT"
  printf 'direct_lock_sha256=%s\n' "$EXPECTED_DIRECT_LOCK_SHA"
  printf 'transaction_lock_sha256=%s\n' "$EXPECTED_TRANSACTION_LOCK_SHA"
  printf 'transaction_packages=%s\n' "${#TRANSACTION_NAMES[@]}"
  printf 'runtime_policy_sha256=%s\n' "$EXPECTED_RUNTIME_POLICY_SHA"
  printf 'runtime_commands=%s\n' "$REQUIRED_COMMANDS"
  printf 'target_user=%s\n' "$TARGET_USER"
  printf 'home_seeded=no\n'
  printf 'session_activated=no\n'
  printf 'uwsm_enabled=no\n'
  printf 'hardware_owned=no\n'
  printf 'updates_owned=no\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage Omarchy shell selection state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set Omarchy shell state permissions'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish Omarchy shell selection state'

printf '%s\n' \
  "[PASS] official packages    ${#TRANSACTION_NAMES[@]} locked versions installed" \
  "[PASS] local userland       $USERLAND_NAME $USERLAND_VERSION installed" \
  "[PASS] runtime commands     $REQUIRED_COMMANDS required commands present" \
  "[PASS] visual defaults      monospace=$MONOSPACE_FAMILY; rendered Tokyo Night packaged" \
  '[PASS] activation boundary  home untouched; no UWSM/display manager/session enabled' \
  '[PASS] shell state          /var/lib/uconsole-omarchy-arm64/omarchy-shell-selection' \
  '' \
  'Next offline step: scripts/prepare-omarchy-user.sh --plan, then --apply.'
