#!/usr/bin/env bash

# Build a bootable Raspberry Pi disk image from a prepared offline Arch Linux
# ARM root. The output is always a new regular .img file. Physical devices,
# existing outputs and the live root are rejected.

set -u
set -o pipefail
umask 022

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

ACTION='plan'
ACTION_SET=0
ROOT_TREE=''
OUTPUT=''
SIZE_MIB=8192
BOOT_MIB=512
DISK_ID=''
BOOT_ID=''
ROOT_UUID=''
SOURCE_DATE_EPOCH=''
REQUIRE_OMARCHY_PREPARED=0
ALLOW_DEFAULT_CREDENTIALS=0
FSTAB_TEMPLATE="$REPO_ROOT/config/image/fstab.template"
CMDLINE_TEMPLATE="$REPO_ROOT/config/image/cmdline.txt.template"
BASE_PACKAGE_LOCK="$REPO_ROOT/config/base-system/packages.lock"
SSHD_TEMPLATE="$REPO_ROOT/config/base-system/sshd_config.template"

EXPECTED_KERNEL='linux-rpi-16k'
EXPECTED_KERNEL_VERSION='6.18.45-1'
EXPECTED_KERNEL_RELEASE='6.18.45-1-rpi-16k'
EXPECTED_BOARD_COMMIT='bf7a0ab55654c96b74d013520e1196d39f66391a'

usage() {
  printf '%s\n' \
    'Usage: build-image.sh --root-tree DIR --output FILE --disk-id HEX8 \' \
    '  --boot-id HEX8 --root-uuid UUID --source-date-epoch EPOCH [options]' \
    '' \
    'Actions:' \
    '  --plan                   Validate and print image geometry (default)' \
    '  --build                  Build a new regular image (Linux root only)' \
    '' \
    'Options:' \
    '  --size-mib N             Image size in MiB (default: 8192; minimum: 2048)' \
    '  --boot-mib N             FAT boot size in MiB (default: 512; minimum: 256)' \
    '  --require-omarchy-prepared' \
    '                           Require the exact inactive Hyprland/Omarchy user seed' \
    '  --fstab-template FILE    Alternate complete template (tests)' \
    '  --cmdline-template FILE  Alternate complete template (tests)' \
    '  --help                   Show this help' \
    '' \
    'The builder never accepts a block device. It preserves the prepared root' \
    'tree and retains a failed .partial image for diagnosis.'
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
    --build) set_action build; shift ;;
    --root-tree) (($# >= 2)) || install_common_die '--root-tree requires a directory'; ROOT_TREE=$2; shift 2 ;;
    --output) (($# >= 2)) || install_common_die '--output requires a file'; OUTPUT=$2; shift 2 ;;
    --size-mib) (($# >= 2)) || install_common_die '--size-mib requires an integer'; SIZE_MIB=$2; shift 2 ;;
    --boot-mib) (($# >= 2)) || install_common_die '--boot-mib requires an integer'; BOOT_MIB=$2; shift 2 ;;
    --disk-id) (($# >= 2)) || install_common_die '--disk-id requires eight hexadecimal characters'; DISK_ID=$2; shift 2 ;;
    --boot-id) (($# >= 2)) || install_common_die '--boot-id requires eight hexadecimal characters'; BOOT_ID=$2; shift 2 ;;
    --root-uuid) (($# >= 2)) || install_common_die '--root-uuid requires a UUID'; ROOT_UUID=$2; shift 2 ;;
    --source-date-epoch) (($# >= 2)) || install_common_die '--source-date-epoch requires an integer'; SOURCE_DATE_EPOCH=$2; shift 2 ;;
    --require-omarchy-prepared) REQUIRE_OMARCHY_PREPARED=1; shift ;;
    --allow-default-credentials) ALLOW_DEFAULT_CREDENTIALS=1; shift ;;
    --fstab-template) (($# >= 2)) || install_common_die '--fstab-template requires a file'; FSTAB_TEMPLATE=$2; shift 2 ;;
    --cmdline-template) (($# >= 2)) || install_common_die '--cmdline-template requires a file'; CMDLINE_TEMPLATE=$2; shift 2 ;;
    --device|--write-device|--i-understand-this-erases-the-device)
      install_common_die "$1 is forbidden; this builder accepts a new regular image only"
      ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ -n "$OUTPUT" ]] || install_common_die '--output is required'
case "$OUTPUT" in
  /|/dev|/dev/*) install_common_die "unsafe output path: $OUTPUT" ;;
  *.img) ;;
  *) install_common_die 'output path must end in .img' ;;
esac
OUTPUT_NAME=${OUTPUT##*/}
[[ "$OUTPUT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.img$ ]] || install_common_die 'output filename must be JSON-safe and contain only letters, digits, dot, underscore or hyphen'
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || install_common_die "refusing existing output path: $OUTPUT"
MANIFEST_OUTPUT="${OUTPUT}.manifest.json"
[[ ! -e "$MANIFEST_OUTPUT" && ! -L "$MANIFEST_OUTPUT" ]] || install_common_die "refusing existing manifest path: $MANIFEST_OUTPUT"
OUTPUT_PARENT=${OUTPUT%/*}
if [[ "$OUTPUT_PARENT" == "$OUTPUT" ]]; then OUTPUT_PARENT='.'; fi
[[ -d "$OUTPUT_PARENT" && -w "$OUTPUT_PARENT" ]] || install_common_die "output parent is not writable: $OUTPUT_PARENT"
OUTPUT_PARENT=$(cd -- "$OUTPUT_PARENT" && pwd -P) || install_common_die 'unable to resolve output parent'
case "$OUTPUT_PARENT" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*) install_common_die "unsafe resolved output parent: $OUTPUT_PARENT" ;; esac
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
MANIFEST_OUTPUT="${OUTPUT}.manifest.json"

case "$SIZE_MIB:$BOOT_MIB:$SOURCE_DATE_EPOCH" in *[!0-9:]*) install_common_die 'sizes and source-date-epoch must be decimal integers' ;; esac
((SIZE_MIB >= 2048)) || install_common_die '--size-mib must be at least 2048'
((BOOT_MIB >= 256)) || install_common_die '--boot-mib must be at least 256'
((SIZE_MIB > BOOT_MIB + 512)) || install_common_die 'image must leave at least 512 MiB beyond the boot partition'
((SOURCE_DATE_EPOCH > 0)) || install_common_die '--source-date-epoch must be positive'

DISK_ID=$(printf '%s' "$DISK_ID" | tr '[:upper:]' '[:lower:]')
BOOT_ID=$(printf '%s' "$BOOT_ID" | tr '[:lower:]' '[:upper:]')
[[ "$DISK_ID" =~ ^[0-9a-f]{8}$ && "$DISK_ID" != '00000000' ]] || install_common_die '--disk-id must be eight nonzero hexadecimal characters'
[[ "$BOOT_ID" =~ ^[0-9A-F]{8}$ && "$BOOT_ID" != '00000000' ]] || install_common_die '--boot-id must be eight nonzero hexadecimal characters'
[[ "$ROOT_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || install_common_die '--root-uuid is not an RFC 4122 UUID'
ROOT_UUID=$(printf '%s' "$ROOT_UUID" | tr '[:upper:]' '[:lower:]')

install_common_require_file 'fstab template' "$FSTAB_TEMPLATE"
install_common_require_file 'cmdline template' "$CMDLINE_TEMPLATE"
[[ $(grep -Fo '@ROOT_PARTUUID@' "$FSTAB_TEMPLATE" | wc -l | tr -d ' ') -eq 1 ]] || install_common_die 'fstab template must contain one @ROOT_PARTUUID@ token'
[[ $(grep -Fo '@BOOT_PARTUUID@' "$FSTAB_TEMPLATE" | wc -l | tr -d ' ') -eq 1 ]] || install_common_die 'fstab template must contain one @BOOT_PARTUUID@ token'
[[ $(grep -Fo '@ROOT_PARTUUID@' "$CMDLINE_TEMPLATE" | wc -l | tr -d ' ') -eq 1 ]] || install_common_die 'cmdline template must contain one @ROOT_PARTUUID@ token'
[[ $(wc -l < "$CMDLINE_TEMPLATE" | tr -d ' ') -eq 1 ]] || install_common_die 'cmdline template must contain exactly one line'

ROOT_TREE=$(install_common_require_offline_arch_root "$ROOT_TREE") || exit 2
case "$OUTPUT_PARENT/" in "$ROOT_TREE"/*) install_common_die 'output parent must not be the prepared root or one of its descendants' ;; esac
HARDWARE_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/hardware-selection"
install_common_require_file 'hardware selection state' "$HARDWARE_STATE"
state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$HARDWARE_STATE"
}
[[ "$(state_field kernel_package)" == "$EXPECTED_KERNEL" ]] || install_common_die 'hardware state does not select linux-rpi-16k'
[[ "$(state_field kernel_version)" == "$EXPECTED_KERNEL_VERSION" ]] || install_common_die 'hardware state has an unexpected kernel version'
[[ "$(state_field kernel_release)" == "$EXPECTED_KERNEL_RELEASE" ]] || install_common_die 'hardware state has an unexpected kernel release'
[[ "$(state_field board_source_commit)" == "$EXPECTED_BOARD_COMMIT" ]] || install_common_die 'hardware state has an unaudited board source commit'

# By default a development image must never be built from the signed source
# root while its public default accounts are still usable. Require the exact
# completed base-system transactions and verify their security-critical
# effects.
#
# --allow-default-credentials deliberately trades that for a first-boot
# workflow: the operator boots an unconfigured image on the uConsole's own
# console and sets identity, access and locale there. That is only viable
# while the built-in panel and keyboard work, so the relaxed path is not a
# quiet downgrade. It proves a console login actually exists, it refuses to
# combine with a prepared desktop payload, and it records the choice in both
# the plan output and the image manifest.
BASE_PACKAGE_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-packages"
BASE_SELECTION_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/base-system-selection"
install_common_require_file 'base-system package state' "$BASE_PACKAGE_STATE"
install_common_require_file 'base-system package lock' "$BASE_PACKAGE_LOCK"

# The package layer is verified on both paths: relaxing operator identity must
# not also relax the integrity of what was installed.
EXPECTED_BASE_PACKAGES=$(awk -F '|' '$0 !~ /^#/ { print $1 "=" $2 }' "$BASE_PACKAGE_LOCK") || install_common_die 'unable to render expected base-system package state'
OBSERVED_BASE_PACKAGES=$(sed -n '1,$p' "$BASE_PACKAGE_STATE") || install_common_die 'unable to read base-system package state'
[[ "$OBSERVED_BASE_PACKAGES" == "$EXPECTED_BASE_PACKAGES" ]] || install_common_die 'base-system package state does not match the exact lock'

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"
  else stat -f '%Lp' "$1"
  fi
}

if [[ $ALLOW_DEFAULT_CREDENTIALS -eq 1 ]]; then
  # A prepared desktop payload is seeded into a specific configured admin's
  # home, so there is no coherent meaning for it on an unconfigured root.
  ((REQUIRE_OMARCHY_PREPARED == 0)) || install_common_die '--allow-default-credentials cannot be combined with --require-omarchy-prepared'
  [[ ! -e "$BASE_SELECTION_STATE" ]] || install_common_die 'root is already configured; build it without --allow-default-credentials'

  # Without this check the relaxed path could hand back an image whose every
  # account is locked, which on a serial-less uConsole is unreachable and can
  # only be recovered by re-imaging. Require a real console login to exist.
  install_common_require_file 'target passwd database' "$ROOT_TREE/etc/passwd"
  LOGIN_CAPABLE=$(awk -F ':' '
    FNR == NR {
      shell[$1] = $7
      next
    }
    # A hashed password is necessary but not sufficient: a nologin/false shell
    # or an expired account (field 8) cannot reach a console prompt.
    $2 ~ /^\$/ {
      s = shell[$1]
      if (s == "" || s ~ /(nologin|\/false)$/) next
      if ($8 != "" && $8 + 0 > 0) next
      print $1
    }
  ' "$ROOT_TREE/etc/passwd" "$ROOT_TREE/etc/shadow") || install_common_die 'unable to read target account databases'
  [[ -n "$LOGIN_CAPABLE" ]] || install_common_die 'no account can reach a console login; the unconfigured image would be unreachable without serial access'
  LOGIN_ACCOUNTS=$(printf '%s' "$LOGIN_CAPABLE" | paste -sd, -)

  FIRST_BOOT_POLICY="unconfigured; default credentials; console login: $LOGIN_ACCOUNTS"
  FIRST_BOOT_MANIFEST_STATE='unconfigured-default-credentials'
  printf '%s\n' \
    'WARNING: building an UNCONFIGURED image with default credentials.' \
    "WARNING: these accounts keep their public default passwords: $LOGIN_ACCOUNTS" \
    'WARNING: SSH is not restricted to key-only and no admin identity exists yet.' \
    'WARNING: set identity, access and locale at the first console login, and do' \
    'WARNING: not attach this image to an untrusted network beforehand.' >&2
else

install_common_require_file 'base-system selection state' "$BASE_SELECTION_STATE"
install_common_require_file 'sshd policy template' "$SSHD_TEMPLATE"

base_state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$BASE_SELECTION_STATE"
}
[[ $(awk 'END { print NR }' "$BASE_SELECTION_STATE") -eq 9 ]] || install_common_die 'base-system selection state must contain exactly nine fields'
ADMIN_USER=$(base_state_field admin_user) || install_common_die 'base-system selection lacks one admin user'
IMAGE_HOSTNAME=$(base_state_field hostname) || install_common_die 'base-system selection lacks one hostname'
IMAGE_TIMEZONE=$(base_state_field timezone) || install_common_die 'base-system selection lacks one timezone'
IMAGE_LOCALE=$(base_state_field locale) || install_common_die 'base-system selection lacks one locale'
IMAGE_KEYMAP=$(base_state_field keymap) || install_common_die 'base-system selection lacks one keymap'
IMAGE_REG_DOMAIN=$(base_state_field reg_domain) || install_common_die 'base-system selection lacks one regulatory domain'
SSH_KEY_FINGERPRINT=$(base_state_field ssh_key_fingerprint) || install_common_die 'base-system selection lacks one SSH fingerprint'
WIFI_PRESEED=$(base_state_field wifi_preseed) || install_common_die 'base-system selection lacks one Wi-Fi policy'
[[ $(base_state_field network_manager) == NetworkManager ]] || install_common_die 'base-system selection does not assign networking to NetworkManager'

[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || install_common_die 'base-system admin user is unsafe'
[[ "$IMAGE_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || install_common_die 'base-system hostname is unsafe'
[[ "$IMAGE_TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || install_common_die 'base-system timezone is unsafe'
[[ "$IMAGE_LOCALE" == en_US.UTF-8 && "$IMAGE_KEYMAP" == us ]] || install_common_die 'base-system locale or keymap is unaudited'
[[ "$IMAGE_REG_DOMAIN" =~ ^[A-Z]{2}$ ]] || install_common_die 'base-system regulatory domain is unsafe'
[[ "$SSH_KEY_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]+={0,2}$ ]] || install_common_die 'base-system SSH fingerprint is unsafe'
[[ "$WIFI_PRESEED" == yes || "$WIFI_PRESEED" == no ]] || install_common_die 'base-system Wi-Fi policy is unsafe'

ADMIN_ENTRY=$(awk -F ':' -v wanted="$ADMIN_USER" '$1 == wanted { count++; uid=$3; home=$6 } END { if (count == 1) print uid ":" home; else exit 1 }' "$ROOT_TREE/etc/passwd") || install_common_die 'configured admin account is missing or duplicated'
IFS=':' read -r ADMIN_UID ADMIN_HOME <<< "$ADMIN_ENTRY"
((ADMIN_UID >= 1000)) || install_common_die 'configured admin account has a system or root UID'
[[ "$ADMIN_HOME" == "/home/$ADMIN_USER" ]] || install_common_die 'configured admin account has an unexpected home'
awk -F ':' '$1 == "root" { found=1; valid=($2 ~ /^!|^\*/) } END { exit !(found && valid) }' "$ROOT_TREE/etc/shadow" || install_common_die 'root account is not locked'
awk -F ':' -v wanted="$ADMIN_USER" '$1 == wanted { found=1; valid=($2 ~ /^\$y\$|^\$6\$/) } END { exit !(found && valid) }' "$ROOT_TREE/etc/shadow" || install_common_die 'admin account lacks an encrypted local-console recovery hash'
if [[ "$ADMIN_USER" != alarm ]]; then
  awk -F ':' '$1 == "alarm" { found=1; valid=($2 ~ /^!|^\*/) } END { exit !(found && valid) }' "$ROOT_TREE/etc/shadow" || install_common_die 'non-admin source alarm account is not locked'
fi
grep -Eq "^wheel:[^:]*:[^:]*:.*(^|,)${ADMIN_USER}(,|$)" "$ROOT_TREE/etc/group" || install_common_die 'configured admin is not in wheel'

AUTHORIZED_KEYS="$ROOT_TREE$ADMIN_HOME/.ssh/authorized_keys"
[[ -s "$AUTHORIZED_KEYS" && -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]] || install_common_die 'configured admin authorized_keys is missing, empty or unsafe'
[[ $(file_mode "$AUTHORIZED_KEYS") == 600 ]] || install_common_die 'configured admin authorized_keys mode is not 0600'
EXPECTED_SSHD_POLICY=$(sed "s/@ADMIN_USER@/$ADMIN_USER/g" "$SSHD_TEMPLATE") || install_common_die 'unable to render expected sshd policy'
OBSERVED_SSHD_POLICY=$(sed -n '1,$p' "$ROOT_TREE/etc/ssh/sshd_config.d/10-uconsole.conf") || install_common_die 'unable to read configured sshd policy'
[[ "$OBSERVED_SSHD_POLICY" == "$EXPECTED_SSHD_POLICY" ]] || install_common_die 'configured sshd policy differs from the audited template'
[[ $(sed -n '1p' "$ROOT_TREE/etc/hostname") == "$IMAGE_HOSTNAME" ]] || install_common_die 'configured hostname differs from selection state'
grep -Fqx "LANG=$IMAGE_LOCALE" "$ROOT_TREE/etc/locale.conf" || install_common_die 'configured locale differs from selection state'
grep -Fqx "KEYMAP=$IMAGE_KEYMAP" "$ROOT_TREE/etc/vconsole.conf" || install_common_die 'configured keymap differs from selection state'
[[ -L "$ROOT_TREE/etc/localtime" && $(readlink "$ROOT_TREE/etc/localtime") == "/usr/share/zoneinfo/$IMAGE_TIMEZONE" ]] || install_common_die 'configured timezone differs from selection state'
grep -Fqx "options cfg80211 ieee80211_regdom=$IMAGE_REG_DOMAIN" "$ROOT_TREE/etc/modprobe.d/90-uconsole-regdom.conf" || install_common_die 'configured regulatory domain differs from selection state'
grep -Fqx 'dns=systemd-resolved' "$ROOT_TREE/etc/NetworkManager/conf.d/10-uconsole.conf" || install_common_die 'configured NetworkManager DNS policy is missing'

WIFI_DEST="$ROOT_TREE/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection"
if [[ "$WIFI_PRESEED" == yes ]]; then
  [[ -s "$WIFI_DEST" && -f "$WIFI_DEST" && ! -L "$WIFI_DEST" ]] || install_common_die 'selected bootstrap Wi-Fi connection is missing or unsafe'
  [[ $(file_mode "$WIFI_DEST") == 600 ]] || install_common_die 'bootstrap Wi-Fi connection mode is not 0600'
else
  [[ ! -e "$WIFI_DEST" && ! -L "$WIFI_DEST" ]] || install_common_die 'bootstrap Wi-Fi connection exists despite selection state'
fi

FIRST_BOOT_POLICY="admin=$ADMIN_USER key-only SSH; source accounts locked; network=$WIFI_PRESEED"
FIRST_BOOT_MANIFEST_STATE='configured'

fi

OMARCHY_IMAGE_STATE='not-required'
if [[ $REQUIRE_OMARCHY_PREPARED -eq 1 ]]; then
  # This gate deliberately proves only that the reviewed desktop payload and
  # user seed are present. It also proves that no session handoff was enabled.
  # Live CM5 GPU validation remains a separate prerequisite for activation.
  HYPRLAND_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/hyprland-selection"
  OMARCHY_SHELL_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection"
  OMARCHY_USER_STATE="$ROOT_TREE/var/lib/uconsole-omarchy-arm64/user-preparation-$ADMIN_USER"
  install_common_require_file 'Hyprland selection state' "$HYPRLAND_STATE"
  install_common_require_file 'Omarchy shell selection state' "$OMARCHY_SHELL_STATE"
  install_common_require_file 'Omarchy user-preparation state' "$OMARCHY_USER_STATE"

  exact_state_field() {
    local state_file=$1
    local key=$2
    awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$state_file"
  }

  [[ $(exact_state_field "$HYPRLAND_STATE" hyprland_version) == '0.56.1-3' ]] || install_common_die 'Hyprland state has an unexpected version'
  [[ $(exact_state_field "$HYPRLAND_STATE" package_lock_sha256) == '1d469713047d2226bf934586f23073812c698c538a7085e8e4782dee38eba09e' ]] || install_common_die 'Hyprland direct package lock changed'
  [[ $(exact_state_field "$HYPRLAND_STATE" transaction_lock_sha256) == '2bd6232e8e90da7f10e9245fb306f5d7578840e9452d42726607cf52483c1bc7' ]] || install_common_die 'Hyprland transaction lock changed'
  [[ $(exact_state_field "$HYPRLAND_STATE" config_sha256) == 'f944368040661e3d88746e6c521c978a85e5b5beaeb62cf30ef460548adf0b60' ]] || install_common_die 'Hyprland configuration state changed'
  [[ $(exact_state_field "$HYPRLAND_STATE" target_user) == "$ADMIN_USER" ]] || install_common_die 'Hyprland state belongs to a different user'
  [[ $(exact_state_field "$HYPRLAND_STATE" session_start) == 'start-hyprland' ]] || install_common_die 'Hyprland state has an unexpected manual session handoff'
  [[ $(exact_state_field "$HYPRLAND_STATE" uwsm_enabled) == no ]] || install_common_die 'Hyprland state reports UWSM activation'

  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" userland_version) == '4.0.0.alpha-3' ]] || install_common_die 'Omarchy shell state has an unexpected userland version'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" userland_sha256) == '4824a5b829cf6633e0d329307341398353fe14881c9642730e96bb7c31d93b71' ]] || install_common_die 'Omarchy shell package digest changed'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" upstream_commit) == 'd99d4fc6de0bc99d48c9935724fa19d7fb41ae54' ]] || install_common_die 'Omarchy shell state has an unexpected upstream commit'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" transaction_lock_sha256) == '9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3' ]] || install_common_die 'Omarchy shell transaction lock changed'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" runtime_policy_sha256) == '5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d' ]] || install_common_die 'Omarchy runtime policy changed'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" target_user) == "$ADMIN_USER" ]] || install_common_die 'Omarchy shell state belongs to a different user'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" home_seeded) == no ]] || install_common_die 'Omarchy package transaction unexpectedly reports a user seed'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" session_activated) == no ]] || install_common_die 'Omarchy shell state reports session activation'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" uwsm_enabled) == no ]] || install_common_die 'Omarchy shell state reports UWSM activation'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" hardware_owned) == no ]] || install_common_die 'Omarchy shell state reports hardware ownership'
  [[ $(exact_state_field "$OMARCHY_SHELL_STATE" updates_owned) == no ]] || install_common_die 'Omarchy shell state reports update ownership'

  [[ $(exact_state_field "$OMARCHY_USER_STATE" target_user) == "$ADMIN_USER" ]] || install_common_die 'Omarchy user-preparation state belongs to a different user'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" upstream_commit) == 'd99d4fc6de0bc99d48c9935724fa19d7fb41ae54' ]] || install_common_die 'Omarchy user-preparation commit changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" shell_sha256) == 'b8f1995c5fbfe55252463c47f21cce833154f905a92d493a03981a21eac8ac9a' ]] || install_common_die 'prepared Omarchy shell configuration digest changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" foot_sha256) == 'a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf' ]] || install_common_die 'prepared Foot configuration digest changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" migration_count) == 87 ]] || install_common_die 'prepared migration baseline count changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" migration_lock_sha256) == 'bf1cd979738bc9035731e881fae95072d64caf2bacb3705f9a47433a0aa7b143' ]] || install_common_die 'prepared migration baseline lock changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" historical_migrations_run) == no ]] || install_common_die 'prepared state reports historical migration execution'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" initial_theme) == 'tokyo-night' ]] || install_common_die 'prepared initial theme changed'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" session_modified) == no ]] || install_common_die 'prepared state reports session modification'
  [[ $(exact_state_field "$OMARCHY_USER_STATE" activation) == no ]] || install_common_die 'prepared state reports activation'

  ADMIN_HYPR_CONFIG="$ROOT_TREE$ADMIN_HOME/.config/hypr/hyprland.lua"
  ADMIN_SHELL_CONFIG="$ROOT_TREE$ADMIN_HOME/.config/omarchy/shell.json"
  ADMIN_FOOT_CONFIG="$ROOT_TREE$ADMIN_HOME/.config/foot/foot.ini"
  ADMIN_OMARCHY_CURRENT="$ROOT_TREE$ADMIN_HOME/.local/state/omarchy/current"
  install_common_require_file 'prepared Hyprland configuration' "$ADMIN_HYPR_CONFIG"
  install_common_require_file 'prepared Omarchy shell configuration' "$ADMIN_SHELL_CONFIG"
  install_common_require_file 'prepared Foot configuration' "$ADMIN_FOOT_CONFIG"
  [[ $(install_common_sha256 "$ADMIN_HYPR_CONFIG") == 'f944368040661e3d88746e6c521c978a85e5b5beaeb62cf30ef460548adf0b60' ]] || install_common_die 'prepared Hyprland configuration differs from selection state'
  [[ $(install_common_sha256 "$ADMIN_SHELL_CONFIG") == 'b8f1995c5fbfe55252463c47f21cce833154f905a92d493a03981a21eac8ac9a' ]] || install_common_die 'prepared Omarchy shell configuration differs from selection state'
  [[ $(install_common_sha256 "$ADMIN_FOOT_CONFIG") == 'a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf' ]] || install_common_die 'prepared Foot configuration differs from selection state'
  [[ -L "$ADMIN_OMARCHY_CURRENT/theme" && $(readlink "$ADMIN_OMARCHY_CURRENT/theme") == '/usr/share/omarchy-arm64/themes/tokyo-night' ]] || install_common_die 'prepared initial theme link differs'
  [[ -L "$ADMIN_OMARCHY_CURRENT/background" && $(readlink "$ADMIN_OMARCHY_CURRENT/background") == '/usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp' ]] || install_common_die 'prepared initial background link differs'
  [[ -f "$ADMIN_OMARCHY_CURRENT/theme.name" && ! -L "$ADMIN_OMARCHY_CURRENT/theme.name" ]] || install_common_die 'prepared initial theme name is missing or unsafe'
  [[ $(sed -n '1p' "$ADMIN_OMARCHY_CURRENT/theme.name") == 'tokyo-night' ]] || install_common_die 'prepared initial theme name differs'
  OMARCHY_IMAGE_STATE='prepared-inactive'
fi
HOST_KEY=$(find "$ROOT_TREE/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit) || install_common_die 'unable to inspect SSH host keys'
[[ -z "$HOST_KEY" ]] || install_common_die 'prepared root contains an SSH host key that would be cloned'

for required in \
  "$ROOT_TREE/boot/config.txt" \
  "$ROOT_TREE/boot/kernel8.img" \
  "$ROOT_TREE/boot/initramfs-linux.img" \
  "$ROOT_TREE/boot/start4.elf" \
  "$ROOT_TREE/boot/fixup4.dat" \
  "$ROOT_TREE/boot/bcm2712-rpi-cm5-cm5io.dtb" \
  "$ROOT_TREE/boot/overlays/vc4-kms-v3d.dtbo" \
  "$ROOT_TREE/boot/uconsole-cm5.txt" \
  "$ROOT_TREE/boot/overlays/uconsole-cm5-base.dtbo" \
  "$ROOT_TREE/boot/overlays/uconsole-audio-cm5.dtbo"; do
  [[ -s "$required" && ! -L "$required" ]] || install_common_die "required boot artifact is missing, empty or a symlink: $required"
done
[[ -f "$ROOT_TREE/etc/fstab" && ! -L "$ROOT_TREE/etc/fstab" ]] || install_common_die 'prepared root has no safe /etc/fstab'
[[ -f "$ROOT_TREE/boot/cmdline.txt" && ! -L "$ROOT_TREE/boot/cmdline.txt" ]] || install_common_die 'prepared root has no safe /boot/cmdline.txt'
if find "$ROOT_TREE/boot" -type l -print -quit | grep -q .; then
  install_common_die 'FAT boot source contains a symbolic link, which cannot be represented faithfully'
fi
[[ $(grep -Fxc '# BEGIN uconsole-omarchy-arm64 hardware include' "$ROOT_TREE/boot/config.txt") -eq 1 ]] || install_common_die 'boot config lacks exactly one managed hardware include marker'
grep -Fqx 'include uconsole-cm5.txt' "$ROOT_TREE/boot/config.txt" || install_common_die 'boot config does not include uconsole-cm5.txt'

SECTOR_SIZE=512
SECTORS_PER_MIB=2048
FIRST_SECTOR=8192
TOTAL_SECTORS=$((SIZE_MIB * SECTORS_PER_MIB))
BOOT_SECTORS=$((BOOT_MIB * SECTORS_PER_MIB))
ROOT_START=$((FIRST_SECTOR + BOOT_SECTORS))
END_RESERVE=2048
ROOT_SECTORS=$((TOTAL_SECTORS - ROOT_START - END_RESERVE))
((ROOT_SECTORS > 0)) || install_common_die 'computed root partition is empty'
BOOT_PARTUUID="${DISK_ID}-01"
ROOT_PARTUUID="${DISK_ID}-02"

ROOT_BYTES=$(du -sk "$ROOT_TREE" | awk '{print $1 * 1024}') || install_common_die 'unable to measure prepared root tree'
ROOT_CAPACITY=$((ROOT_SECTORS * SECTOR_SIZE))
REQUIRED_CAPACITY=$((ROOT_BYTES + 512 * 1024 * 1024))
((ROOT_CAPACITY >= REQUIRED_CAPACITY)) || install_common_die "root partition lacks 512 MiB headroom: content=$ROOT_BYTES capacity=$ROOT_CAPACITY"
BOOT_BYTES=$(du -sk "$ROOT_TREE/boot" | awk '{print $1 * 1024}') || install_common_die 'unable to measure boot tree'
BOOT_CAPACITY=$((BOOT_SECTORS * SECTOR_SIZE))
REQUIRED_BOOT_CAPACITY=$((BOOT_BYTES + 32 * 1024 * 1024))
((BOOT_CAPACITY >= REQUIRED_BOOT_CAPACITY)) || install_common_die "boot partition lacks 32 MiB headroom: content=$BOOT_BYTES capacity=$BOOT_CAPACITY"

printf '%s\n' \
  '[PASS] prepared root         Arch Linux ARM identity and exact hardware state present' \
  "[PASS] first-boot policy    $FIRST_BOOT_POLICY" \
  '[PASS] boot artifacts        kernel, CM5 DTB, uConsole overlays and managed include present' \
  "[PASS] Omarchy image state   $OMARCHY_IMAGE_STATE" \
  "[PASS] output safety        new regular image path under $OUTPUT_PARENT" \
  "[PASS] root headroom        content=$ROOT_BYTES capacity=$ROOT_CAPACITY" \
  "[PASS] boot headroom        content=$BOOT_BYTES capacity=$BOOT_CAPACITY" \
  '' \
  "Action: $ACTION" \
  "Output: $OUTPUT" \
  "Image size: $SIZE_MIB MiB ($TOTAL_SECTORS sectors)" \
  "Disk ID: $DISK_ID" \
  "Boot: start=$FIRST_SECTOR sectors=$BOOT_SECTORS PARTUUID=$BOOT_PARTUUID FAT-ID=$BOOT_ID" \
  "Root: start=$ROOT_START sectors=$ROOT_SECTORS PARTUUID=$ROOT_PARTUUID UUID=$ROOT_UUID" \
  ''

if [[ "$ACTION" == 'plan' ]]; then
  printf '%s\n' \
    'Plan complete. The prepared root, output path, loop devices and physical devices were unchanged.' \
    'Build mode is Linux/root-only and still refuses every /dev output.'
  exit 0
fi

[[ "$(uname -s)" == 'Linux' ]] || install_common_die '--build requires Linux'
[[ $EUID -eq 0 ]] || install_common_die '--build requires root for loop and mount operations'
for command_name in sfdisk losetup mkfs.fat fsck.fat mkfs.ext4 e2fsck mount umount mountpoint bsdtar sha256sum findmnt; do
  command -v "$command_name" >/dev/null 2>&1 || install_common_die "required build command is missing: $command_name"
done

NESTED_MOUNTS=''
NESTED_MOUNTS=$(findmnt -rn -R -o TARGET "$ROOT_TREE" 2>/dev/null)
while IFS= read -r mount_target; do
  [[ -n "$mount_target" ]] || continue
  [[ "$mount_target" == "$ROOT_TREE" ]] || install_common_die "prepared root contains a nested mount: $mount_target"
done <<< "$NESTED_MOUNTS"

PARTIAL="${OUTPUT}.partial.$$"
[[ ! -e "$PARTIAL" && ! -L "$PARTIAL" ]] || install_common_die "partial output already exists: $PARTIAL"
MOUNT_ROOT=$(mktemp -d "$OUTPUT_PARENT/.uconsole-image-mount.XXXXXX") || install_common_fail 'unable to create image mount directory'
BOOT_LOOP_DEVICE=''
ROOT_LOOP_DEVICE=''
BOOT_MOUNTED=0
ROOT_MOUNTED=0

cleanup_resources() {
  local cleanup_status=0
  if [[ $BOOT_MOUNTED -eq 1 ]]; then
    if mountpoint -q "$MOUNT_ROOT/boot"; then
      if ! umount "$MOUNT_ROOT/boot"; then
        printf 'ERROR: unable to unmount temporary boot filesystem: %s\n' "$MOUNT_ROOT/boot" >&2
        cleanup_status=1
      fi
    fi
    BOOT_MOUNTED=0
  fi
  if [[ $ROOT_MOUNTED -eq 1 ]]; then
    if mountpoint -q "$MOUNT_ROOT"; then
      if ! umount "$MOUNT_ROOT"; then
        printf 'ERROR: unable to unmount temporary root filesystem: %s\n' "$MOUNT_ROOT" >&2
        cleanup_status=1
      fi
    fi
    ROOT_MOUNTED=0
  fi
  if [[ -n "$ROOT_LOOP_DEVICE" ]]; then
    if ! losetup -d "$ROOT_LOOP_DEVICE"; then
      printf 'ERROR: unable to detach temporary root loop device: %s\n' "$ROOT_LOOP_DEVICE" >&2
      cleanup_status=1
    fi
    ROOT_LOOP_DEVICE=''
  fi
  if [[ -n "$BOOT_LOOP_DEVICE" ]]; then
    if ! losetup -d "$BOOT_LOOP_DEVICE"; then
      printf 'ERROR: unable to detach temporary boot loop device: %s\n' "$BOOT_LOOP_DEVICE" >&2
      cleanup_status=1
    fi
    BOOT_LOOP_DEVICE=''
  fi
  if [[ -d "$MOUNT_ROOT" && $BOOT_MOUNTED -eq 0 && $ROOT_MOUNTED -eq 0 ]]; then
    if ! rmdir "$MOUNT_ROOT"; then
      printf 'ERROR: unable to remove temporary mount directory: %s\n' "$MOUNT_ROOT" >&2
      cleanup_status=1
    fi
  fi
  return "$cleanup_status"
}
cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if ! cleanup_resources && [[ $status -eq 0 ]]; then status=1; fi
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

truncate -s "${SIZE_MIB}M" "$PARTIAL" || install_common_fail 'unable to create sparse partial image'
SFDISK_INPUT="label: dos
label-id: 0x${DISK_ID}
unit: sectors

start=${FIRST_SECTOR}, size=${BOOT_SECTORS}, type=c, bootable
start=${ROOT_START}, size=${ROOT_SECTORS}, type=83"
if ! printf '%s\n' "$SFDISK_INPUT" | sfdisk "$PARTIAL"; then
  install_common_fail 'partition table creation failed'
fi

BOOT_OFFSET=$((FIRST_SECTOR * SECTOR_SIZE))
BOOT_SIZE_BYTES=$((BOOT_SECTORS * SECTOR_SIZE))
ROOT_OFFSET=$((ROOT_START * SECTOR_SIZE))
ROOT_SIZE_BYTES=$((ROOT_SECTORS * SECTOR_SIZE))
BOOT_LOOP_DEVICE=$(losetup --find --show --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE_BYTES" "$PARTIAL") || install_common_fail 'unable to allocate boot-range loop device'
ROOT_LOOP_DEVICE=$(losetup --find --show --offset "$ROOT_OFFSET" --sizelimit "$ROOT_SIZE_BYTES" "$PARTIAL") || install_common_fail 'unable to allocate root-range loop device'
BOOT_DEVICE=$BOOT_LOOP_DEVICE
ROOT_DEVICE=$ROOT_LOOP_DEVICE

mkfs.fat -F 32 --invariant -i "$BOOT_ID" -n UCONSOLE "$BOOT_DEVICE" || install_common_fail 'FAT filesystem creation failed'
E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" mkfs.ext4 -F -L uconsole-root -U "$ROOT_UUID" \
  -E lazy_itable_init=0,lazy_journal_init=0 "$ROOT_DEVICE" || install_common_fail 'ext4 filesystem creation failed'

mount -o noatime "$ROOT_DEVICE" "$MOUNT_ROOT" || install_common_fail 'unable to mount temporary root filesystem'
ROOT_MOUNTED=1
mkdir -p "$MOUNT_ROOT/boot" || install_common_fail 'unable to create boot mount point'
mount -o noatime "$BOOT_DEVICE" "$MOUNT_ROOT/boot" || install_common_fail 'unable to mount temporary boot filesystem'
BOOT_MOUNTED=1

bsdtar -cpf - --acls --xattrs --no-fflags --numeric-owner --exclude './boot/*' --exclude './etc/fstab' -C "$ROOT_TREE" . | \
  bsdtar -xpf - --acls --xattrs --no-fflags --numeric-owner -C "$MOUNT_ROOT"
COPY_STATUS=("${PIPESTATUS[@]}")
[[ ${COPY_STATUS[0]} -eq 0 && ${COPY_STATUS[1]} -eq 0 ]] || install_common_fail "root tree copy failed: create=${COPY_STATUS[0]} extract=${COPY_STATUS[1]}"
cp -r "$ROOT_TREE/boot/." "$MOUNT_ROOT/boot/" || install_common_fail 'boot tree copy failed'

render_template() {
  local template=$1
  local destination=$2
  sed -e "s/@BOOT_PARTUUID@/$BOOT_PARTUUID/g" -e "s/@ROOT_PARTUUID@/$ROOT_PARTUUID/g" "$template" > "$destination" || return 1
  if grep -Eq '@[A-Z0-9_]+@' "$destination"; then return 1; fi
}
render_template "$FSTAB_TEMPLATE" "$MOUNT_ROOT/etc/fstab" || install_common_fail 'unable to render fstab'
render_template "$CMDLINE_TEMPLATE" "$MOUNT_ROOT/boot/cmdline.txt" || install_common_fail 'unable to render cmdline.txt'
chmod 0644 "$MOUNT_ROOT/etc/fstab" "$MOUNT_ROOT/boot/cmdline.txt" || install_common_fail 'unable to set generated file modes'

IMAGE_STATE_DIR="$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64"
mkdir -p "$IMAGE_STATE_DIR" || install_common_fail 'unable to create image state directory'
FSTAB_SHA=$(sha256sum "$FSTAB_TEMPLATE" | awk '{print $1}')
CMDLINE_SHA=$(sha256sum "$CMDLINE_TEMPLATE" | awk '{print $1}')
{
  printf 'disk_id=%s\n' "$DISK_ID"
  printf 'boot_partuuid=%s\n' "$BOOT_PARTUUID"
  printf 'root_partuuid=%s\n' "$ROOT_PARTUUID"
  printf 'boot_id=%s\n' "$BOOT_ID"
  printf 'root_uuid=%s\n' "$ROOT_UUID"
  printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
  printf 'omarchy_image_state=%s\n' "$OMARCHY_IMAGE_STATE"
  printf 'fstab_template_sha256=%s\n' "$FSTAB_SHA"
  printf 'cmdline_template_sha256=%s\n' "$CMDLINE_SHA"
} > "$IMAGE_STATE_DIR/image-selection" || install_common_fail 'unable to write image selection state'
chmod 0644 "$IMAGE_STATE_DIR/image-selection" || install_common_fail 'unable to set image state mode'

BOOT_MANIFEST="$MOUNT_ROOT/boot/uconsole-build-manifest.json"
BOOT_ROWS="$MOUNT_ROOT/var/tmp/uconsole-boot-files.$$"
mkdir -p "$MOUNT_ROOT/var/tmp" || install_common_fail 'unable to create temporary manifest directory'
find "$MOUNT_ROOT/boot" -type f ! -name 'uconsole-build-manifest.json' -print | LC_ALL=C sort > "$BOOT_ROWS" || install_common_fail 'unable to list boot files'
BOOT_FILE_COUNT=$(wc -l < "$BOOT_ROWS" | tr -d ' ')
{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "source_date_epoch": %s,\n' "$SOURCE_DATE_EPOCH"
  printf '  "disk_id": "%s",\n' "$DISK_ID"
  printf '  "boot_partuuid": "%s",\n' "$BOOT_PARTUUID"
  printf '  "root_partuuid": "%s",\n' "$ROOT_PARTUUID"
  printf '  "boot_id": "%s",\n' "$BOOT_ID"
  printf '  "root_uuid": "%s",\n' "$ROOT_UUID"
  printf '  "boot_files": [\n'
  row_number=0
  while IFS= read -r boot_file; do
    relative=${boot_file#"$MOUNT_ROOT/boot/"}
    case "$relative" in *'"'*|*'\\'*|*$'\n'*|*$'\r'*) install_common_fail "boot filename is not JSON-safe: $relative" ;; esac
    digest=$(sha256sum "$boot_file" | awk '{print $1}')
    size=$(stat -c '%s' "$boot_file")
    row_number=$((row_number + 1))
    if [[ $row_number -lt $BOOT_FILE_COUNT ]]; then comma=','; else comma=''; fi
    printf '    {"path": "%s", "size": %s, "sha256": "%s"}%s\n' "$relative" "$size" "$digest" "$comma"
  done < "$BOOT_ROWS"
  printf '  ]\n'
  printf '}\n'
} > "$BOOT_MANIFEST" || install_common_fail 'unable to write boot manifest'
rm -f -- "$BOOT_ROWS" || install_common_fail 'unable to remove temporary boot file list'

CONFIG_SHA=$(sha256sum "$MOUNT_ROOT/boot/config.txt" | awk '{print $1}')
RENDERED_CMDLINE_SHA=$(sha256sum "$MOUNT_ROOT/boot/cmdline.txt" | awk '{print $1}')
RENDERED_FSTAB_SHA=$(sha256sum "$MOUNT_ROOT/etc/fstab" | awk '{print $1}')
BOOT_MANIFEST_SHA=$(sha256sum "$BOOT_MANIFEST" | awk '{print $1}')
sync

if ! umount "$MOUNT_ROOT/boot"; then install_common_fail 'unable to unmount completed boot filesystem'; fi
BOOT_MOUNTED=0
if ! umount "$MOUNT_ROOT"; then install_common_fail 'unable to unmount completed root filesystem'; fi
ROOT_MOUNTED=0
fsck.fat -n "$BOOT_DEVICE" || install_common_fail 'FAT verification failed'
E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" e2fsck -fn "$ROOT_DEVICE" || install_common_fail 'ext4 verification failed'
if ! losetup -d "$ROOT_LOOP_DEVICE"; then install_common_fail 'unable to detach completed root loop device'; fi
ROOT_LOOP_DEVICE=''
if ! losetup -d "$BOOT_LOOP_DEVICE"; then install_common_fail 'unable to detach completed boot loop device'; fi
BOOT_LOOP_DEVICE=''
trap - EXIT INT TERM
rmdir "$MOUNT_ROOT" || install_common_fail 'unable to remove temporary mount directory'

IMAGE_SHA=$(sha256sum "$PARTIAL" | awk '{print $1}')
IMAGE_BYTES=$(stat -c '%s' "$PARTIAL")
MANIFEST_TMP="${MANIFEST_OUTPUT}.partial.$$"
{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "image": "%s",\n' "$OUTPUT_NAME"
  printf '  "image_size": %s,\n' "$IMAGE_BYTES"
  printf '  "image_sha256": "%s",\n' "$IMAGE_SHA"
  printf '  "source_date_epoch": %s,\n' "$SOURCE_DATE_EPOCH"
  printf '  "omarchy_image_state": "%s",\n' "$OMARCHY_IMAGE_STATE"
  printf '  "first_boot_state": "%s",\n' "$FIRST_BOOT_MANIFEST_STATE"
  printf '  "disk_id": "%s",\n' "$DISK_ID"
  printf '  "boot": {"start_sector": %s, "sectors": %s, "partuuid": "%s", "volume_id": "%s"},\n' "$FIRST_SECTOR" "$BOOT_SECTORS" "$BOOT_PARTUUID" "$BOOT_ID"
  printf '  "root": {"start_sector": %s, "sectors": %s, "partuuid": "%s", "uuid": "%s"},\n' "$ROOT_START" "$ROOT_SECTORS" "$ROOT_PARTUUID" "$ROOT_UUID"
  printf '  "boot_file_count": %s,\n' "$BOOT_FILE_COUNT"
  printf '  "boot_manifest_sha256": "%s",\n' "$BOOT_MANIFEST_SHA"
  printf '  "config_txt_sha256": "%s",\n' "$CONFIG_SHA"
  printf '  "cmdline_txt_sha256": "%s",\n' "$RENDERED_CMDLINE_SHA"
  printf '  "fstab_sha256": "%s"\n' "$RENDERED_FSTAB_SHA"
  printf '}\n'
} > "$MANIFEST_TMP" || install_common_fail 'unable to write external image manifest'
chmod 0644 "$MANIFEST_TMP" || install_common_fail 'unable to set external manifest mode'
mv "$PARTIAL" "$OUTPUT" || install_common_fail 'unable to promote completed image'
mv "$MANIFEST_TMP" "$MANIFEST_OUTPUT" || install_common_fail 'unable to publish external image manifest'

printf '%s\n' \
  "[PASS] image                 $OUTPUT sha256=$IMAGE_SHA" \
  "[PASS] filesystems           FAT-ID=$BOOT_ID ext4-UUID=$ROOT_UUID" \
  "[PASS] boot manifest         files=$BOOT_FILE_COUNT sha256=$BOOT_MANIFEST_SHA" \
  "[PASS] external manifest     $MANIFEST_OUTPUT" \
  '[PASS] device boundary       no physical-device output was accepted'
