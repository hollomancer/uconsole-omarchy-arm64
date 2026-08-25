#!/usr/bin/env bash

# Configure minimal first-boot identity, access, locale and networking inside an
# offline Arch Linux ARM root. Secret inputs are read from local files, never
# printed, persisted in state, or accepted as command-line values.

set -u
set -o pipefail
umask 077

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
ADMIN_USER=''
SSH_PUBLIC_KEY=''
CONSOLE_PASSWORD_HASH_FILE=''
WIFI_KEYFILE=''
REG_DOMAIN=''
HOSTNAME=uconsole
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
CHROOT_COMMAND=arch-chroot

HOSTS_TEMPLATE="$REPO_ROOT/config/base-system/hosts.template"
SSHD_TEMPLATE="$REPO_ROOT/config/base-system/sshd_config.template"
NM_CONFIG="$REPO_ROOT/config/base-system/NetworkManager.conf"
SUDOERS_CONFIG="$REPO_ROOT/config/base-system/sudoers"
EXPECTED_KERNEL=linux-rpi-16k
EXPECTED_KERNEL_VERSION=6.18.45-1
EXPECTED_KERNEL_RELEASE=6.18.45-1-rpi-16k
EXPECTED_BOARD_COMMIT=bf7a0ab55654c96b74d013520e1196d39f66391a

usage() {
  printf '%s\n' \
    'Usage: configure-base-system.sh --root DIR --admin-user USER \' \
    '  --ssh-public-key FILE --console-password-hash-file FILE \' \
    '  --reg-domain CC [options]' \
    '' \
    'Actions:' \
    '  --plan                   Validate and print changes (default)' \
    '  --apply                  Configure only the named offline root' \
    '' \
    'Options:' \
    '  --wifi-keyfile FILE      Prebuilt NetworkManager Wi-Fi keyfile (private)' \
    '  --hostname NAME          Hostname (default: uconsole)' \
    '  --timezone ZONE          IANA zone (default: UTC)' \
    '  --locale LOCALE          Supported value: en_US.UTF-8 (default)' \
    '  --keymap KEYMAP          Supported value: us (default)' \
    '  --chroot-command PATH    arch-chroot-compatible command (test/build use)' \
    '  --help                   Show this help' \
    '' \
    'The password file must contain one yescrypt ($y$) or SHA-512 crypt ($6$)' \
    'hash and be inaccessible to group/other. Plaintext passwords and private' \
    'SSH keys are not accepted. Wi-Fi may be omitted for local-console setup.'
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
    --admin-user) (($# >= 2)) || install_common_die '--admin-user requires a value'; ADMIN_USER=$2; shift 2 ;;
    --ssh-public-key) (($# >= 2)) || install_common_die '--ssh-public-key requires a file'; SSH_PUBLIC_KEY=$2; shift 2 ;;
    --console-password-hash-file) (($# >= 2)) || install_common_die '--console-password-hash-file requires a file'; CONSOLE_PASSWORD_HASH_FILE=$2; shift 2 ;;
    --wifi-keyfile) (($# >= 2)) || install_common_die '--wifi-keyfile requires a file'; WIFI_KEYFILE=$2; shift 2 ;;
    --reg-domain) (($# >= 2)) || install_common_die '--reg-domain requires a two-letter country code'; REG_DOMAIN=$2; shift 2 ;;
    --hostname) (($# >= 2)) || install_common_die '--hostname requires a value'; HOSTNAME=$2; shift 2 ;;
    --timezone) (($# >= 2)) || install_common_die '--timezone requires a value'; TIMEZONE=$2; shift 2 ;;
    --locale) (($# >= 2)) || install_common_die '--locale requires a value'; LOCALE=$2; shift 2 ;;
    --keymap) (($# >= 2)) || install_common_die '--keymap requires a value'; KEYMAP=$2; shift 2 ;;
    --chroot-command) (($# >= 2)) || install_common_die '--chroot-command requires a path'; CHROOT_COMMAND=$2; shift 2 ;;
    --device|--write-device|--allow-live-root|--password|--wifi-password|--private-key)
      install_common_die "$1 is forbidden; use the documented local-file inputs"
      ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || install_common_die '--admin-user must be a safe non-root Linux account name'
[[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || install_common_die '--hostname must be a lowercase RFC-compatible single label'
REG_DOMAIN=$(printf '%s' "$REG_DOMAIN" | tr '[:lower:]' '[:upper:]')
[[ "$REG_DOMAIN" =~ ^[A-Z]{2}$ ]] || install_common_die '--reg-domain must be an explicit two-letter country code'
[[ "$LOCALE" == en_US.UTF-8 ]] || install_common_die 'only the audited en_US.UTF-8 locale is currently supported'
[[ "$KEYMAP" == us ]] || install_common_die 'only the audited us keymap is currently supported'
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || install_common_die '--timezone contains unsafe characters'

ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
HARDWARE_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection"
PACKAGE_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages"
install_common_require_file 'hardware selection state' "$HARDWARE_STATE"
install_common_require_file 'base-system package state' "$PACKAGE_STATE"
state_field_from() {
  local file=$1
  local key=$2
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$file"
}
[[ $(state_field_from "$HARDWARE_STATE" kernel_package) == "$EXPECTED_KERNEL" ]] || install_common_die 'hardware state does not select linux-rpi-16k'
[[ $(state_field_from "$HARDWARE_STATE" kernel_version) == "$EXPECTED_KERNEL_VERSION" ]] || install_common_die 'hardware state has an unexpected kernel version'
[[ $(state_field_from "$HARDWARE_STATE" kernel_release) == "$EXPECTED_KERNEL_RELEASE" ]] || install_common_die 'hardware state has an unexpected kernel release'
[[ $(state_field_from "$HARDWARE_STATE" board_source_commit) == "$EXPECTED_BOARD_COMMIT" ]] || install_common_die 'hardware state has an unaudited board source commit'
[[ $(state_field_from "$PACKAGE_STATE" networkmanager) == 1.58.1-1 ]] || install_common_die 'base-system state has an unexpected NetworkManager version'
[[ $(state_field_from "$PACKAGE_STATE" sudo) == 1.9.17.p2-6 ]] || install_common_die 'base-system state has an unexpected sudo version'
[[ $(state_field_from "$PACKAGE_STATE" bluez) == 5.87-2 ]] || install_common_die 'base-system state has an unexpected BlueZ version'
[[ $(state_field_from "$PACKAGE_STATE" bluez-utils) == 5.87-2 ]] || install_common_die 'base-system state has an unexpected bluez-utils version'

for template in "$HOSTS_TEMPLATE" "$SSHD_TEMPLATE" "$NM_CONFIG" "$SUDOERS_CONFIG"; do
  install_common_require_file template "$template"
done
[[ $(grep -Fo '@HOSTNAME@' "$HOSTS_TEMPLATE" | wc -l | tr -d ' ') -eq 1 ]] || install_common_die 'hosts template must contain one @HOSTNAME@ token'
[[ $(grep -Fo '@ADMIN_USER@' "$SSHD_TEMPLATE" | wc -l | tr -d ' ') -eq 1 ]] || install_common_die 'sshd template must contain one @ADMIN_USER@ token'

install_common_require_file 'SSH public key' "$SSH_PUBLIC_KEY"
[[ $(awk 'END { print NR }' "$SSH_PUBLIC_KEY") -eq 1 ]] || install_common_die 'SSH public key file must contain exactly one line'
SSH_KEY_LINE=$(sed -n '1p' "$SSH_PUBLIC_KEY")
[[ "$SSH_KEY_LINE" != *$'\r'* ]] || install_common_die 'SSH public key contains a forbidden carriage return'
case "$SSH_KEY_LINE" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
  *) install_common_die 'SSH public key must begin with a supported key type and contain no authorized_keys options' ;;
esac
SSH_KEY_INFO=''
if command -v ssh-keygen >/dev/null 2>&1; then
  SSH_KEY_INFO=$(ssh-keygen -lf "$SSH_PUBLIC_KEY" -E sha256 2>&1) || install_common_die "SSH public key validation failed: $SSH_KEY_INFO"
elif [[ "$SSH_PUBLIC_KEY" == "$ROOT"/* ]]; then
  TARGET_PUBLIC_KEY=/${SSH_PUBLIC_KEY#"$ROOT"/}
  if [[ "$CHROOT_COMMAND" == */* ]]; then
    [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
  else
    command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
  fi
  SSH_KEY_INFO=$("$CHROOT_COMMAND" "$ROOT" ssh-keygen -lf "$TARGET_PUBLIC_KEY" -E sha256 2>&1) || install_common_die "target SSH public key validation failed: $SSH_KEY_INFO"
else
  install_common_die 'ssh-keygen is unavailable; the public key must be host-validatable or already inside the offline root'
fi
SSH_KEY_FINGERPRINT=$(printf '%s\n' "$SSH_KEY_INFO" | awk 'NF >= 2 { print $2; exit }')
[[ "$SSH_KEY_FINGERPRINT" == SHA256:* ]] || install_common_die 'unable to derive SSH public-key fingerprint'

install_common_require_file 'console password hash' "$CONSOLE_PASSWORD_HASH_FILE"
file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"
  else stat -f '%Lp' "$1"
  fi
}
PASSWORD_MODE=$(file_mode "$CONSOLE_PASSWORD_HASH_FILE") || install_common_die 'unable to inspect console password hash mode'
[[ "$PASSWORD_MODE" =~ ^[0-7]{3,4}$ ]] || install_common_die 'console password hash has an invalid mode'
(( (8#$PASSWORD_MODE & 8#077) == 0 )) || install_common_die 'console password hash must not be accessible to group or other'
[[ $(awk 'END { print NR }' "$CONSOLE_PASSWORD_HASH_FILE") -eq 1 ]] || install_common_die 'console password hash file must contain exactly one line'
CONSOLE_PASSWORD_HASH=$(sed -n '1p' "$CONSOLE_PASSWORD_HASH_FILE")
[[ ${#CONSOLE_PASSWORD_HASH} -ge 20 && ${#CONSOLE_PASSWORD_HASH} -le 512 ]] || install_common_die 'console password hash length is implausible'
[[ "$CONSOLE_PASSWORD_HASH" == '$y$'* || "$CONSOLE_PASSWORD_HASH" == '$6$'* ]] || install_common_die 'console password hash must use yescrypt or SHA-512 crypt'
[[ "$CONSOLE_PASSWORD_HASH" != *:* && "$CONSOLE_PASSWORD_HASH" != *[[:space:]]* ]] || install_common_die 'console password hash contains a forbidden separator or whitespace'

WIFI_PRESEED=no
WIFI_VALIDATION=not-selected
if [[ -n "$WIFI_KEYFILE" ]]; then
  install_common_require_file 'NetworkManager Wi-Fi keyfile' "$WIFI_KEYFILE"
  WIFI_MODE=$(file_mode "$WIFI_KEYFILE") || install_common_die 'unable to inspect Wi-Fi keyfile mode'
  [[ "$WIFI_MODE" =~ ^[0-7]{3,4}$ ]] || install_common_die 'Wi-Fi keyfile has an invalid mode'
  (( (8#$WIFI_MODE & 8#077) == 0 )) || install_common_die 'Wi-Fi keyfile must not be accessible to group or other'
  WIFI_SIZE=$(wc -c < "$WIFI_KEYFILE" | tr -d ' ')
  ((WIFI_SIZE > 0 && WIFI_SIZE <= 65536)) || install_common_die 'Wi-Fi keyfile must be 1 to 65536 bytes'
  grep -Iq . "$WIFI_KEYFILE" || install_common_die 'Wi-Fi keyfile must be non-binary text'
  WIFI_KEY_MGMT=$(awk -F '=' '
    /^\[/ { current=$0; gsub(/^\[|\]$/, "", current); next }
    current == "wifi-security" && $1 == "key-mgmt" { count++; value=substr($0, index($0, "=") + 1) }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$WIFI_KEYFILE") || install_common_die 'Wi-Fi keyfile lacks one [wifi-security] key-mgmt entry'
  [[ "$WIFI_KEY_MGMT" == wpa-psk || "$WIFI_KEY_MGMT" == sae ]] || install_common_die 'Wi-Fi keyfile key-mgmt must be wpa-psk or sae'
  for required_wifi_value in \
    'connection|type|wifi' \
    'connection|autoconnect|true' \
    'wifi|ssid|' \
    'wifi-security|psk|'; do
    section=${required_wifi_value%%|*}
    remainder=${required_wifi_value#*|}
    key=${remainder%%|*}
    expected=${remainder#*|}
    if ! awk -F '=' -v wanted_section="$section" -v wanted_key="$key" -v wanted_value="$expected" '
      /^\[/ { current=$0; gsub(/^\[|\]$/, "", current); next }
      current == wanted_section && $1 == wanted_key {
        count++
        value=substr($0, index($0, "=") + 1)
      }
      END {
        if (count != 1 || value == "") exit 1
        if (wanted_value != "" && value != wanted_value) exit 1
      }
    ' "$WIFI_KEYFILE"; then
      install_common_die "Wi-Fi keyfile lacks one valid [$section] $key entry"
    fi
  done
  WIFI_VALIDATION=structural
  WIFI_NORMALIZED_SIZE=''
  if [[ "$WIFI_KEYFILE" == "$ROOT"/* ]]; then
    TARGET_WIFI_KEYFILE=/${WIFI_KEYFILE#"$ROOT"/}
    WIFI_NORMALIZED_SIZE=$("$CHROOT_COMMAND" "$ROOT" /usr/bin/bash -o pipefail -c 'nmcli --offline connection modify < "$1" | wc -c' -- "$TARGET_WIFI_KEYFILE" 2>/dev/null) || install_common_die 'target NetworkManager rejected the Wi-Fi keyfile'
    WIFI_NORMALIZED_SIZE=$(printf '%s' "$WIFI_NORMALIZED_SIZE" | tr -d ' ')
    WIFI_VALIDATION=target-nmcli-offline
  elif command -v nmcli >/dev/null 2>&1; then
    WIFI_NORMALIZED_SIZE=$(nmcli --offline connection modify < "$WIFI_KEYFILE" 2>/dev/null | wc -c | tr -d ' ') || install_common_die 'host NetworkManager rejected the Wi-Fi keyfile'
    WIFI_VALIDATION=host-nmcli-offline
  fi
  if [[ -n "$WIFI_NORMALIZED_SIZE" ]]; then
    [[ "$WIFI_NORMALIZED_SIZE" =~ ^[0-9]+$ && "$WIFI_NORMALIZED_SIZE" -gt 0 ]] || install_common_die 'NetworkManager returned an empty Wi-Fi profile'
  fi
  WIFI_PRESEED=yes
fi

ZONEINFO="$ROOT/usr/share/zoneinfo/$TIMEZONE"
[[ -e "$ZONEINFO" ]] || install_common_die "timezone data is missing: $TIMEZONE"
grep -Fqx '#en_US.UTF-8 UTF-8  ' "$ROOT/etc/locale.gen" || grep -Fqx 'en_US.UTF-8 UTF-8  ' "$ROOT/etc/locale.gen" || install_common_die 'locale.gen lacks the expected en_US.UTF-8 source line'

ADMIN_PASSWD_COUNT=$(awk -F ':' -v wanted="$ADMIN_USER" '$1 == wanted { count++; uid=$3; gid=$4; home=$6; shell=$7 } END { if (count == 1) print uid ":" gid ":" home ":" shell; else if (count > 1) exit 1 }' "$ROOT/etc/passwd") || install_common_die 'admin account appears more than once'
if [[ -n "$ADMIN_PASSWD_COUNT" ]]; then
  IFS=':' read -r ADMIN_UID ADMIN_GID ADMIN_HOME ADMIN_SHELL <<< "$ADMIN_PASSWD_COUNT"
  ((ADMIN_UID >= 1000)) || install_common_die 'existing admin account has a system or root UID'
  [[ "$ADMIN_HOME" == "/home/$ADMIN_USER" ]] || install_common_die 'existing admin account has an unexpected home'
  [[ "$ADMIN_SHELL" == /bin/bash || "$ADMIN_SHELL" == /usr/bin/bash ]] || install_common_die 'existing admin account has an unexpected shell'
else
  ADMIN_UID='new'
  ADMIN_GID='new'
  ADMIN_HOME="/home/$ADMIN_USER"
  ADMIN_SHELL=/bin/bash
fi

HOSTS_CONTENT=$(sed "s/@HOSTNAME@/$HOSTNAME/g" "$HOSTS_TEMPLATE") || install_common_die 'unable to render hosts template'
SSHD_CONTENT=$(sed "s/@ADMIN_USER@/$ADMIN_USER/g" "$SSHD_TEMPLATE") || install_common_die 'unable to render sshd template'
[[ "$HOSTS_CONTENT" != *'@HOSTNAME@'* && "$SSHD_CONTENT" != *'@ADMIN_USER@'* ]] || install_common_die 'rendered configuration contains an unresolved token'
HOSTNAME_CONTENT=$HOSTNAME
LOCALE_CONTENT="LANG=$LOCALE"
VCONSOLE_CONTENT="KEYMAP=$KEYMAP"
REGDOM_CONTENT="options cfg80211 ieee80211_regdom=$REG_DOMAIN"

assert_text_destination() {
  local path=$1
  local desired=$2
  local source_default=${3-}
  [[ ! -L "$path" ]] || install_common_die "managed destination must not be a symlink: $path"
  [[ -e "$path" ]] || return 0
  [[ -f "$path" ]] || install_common_die "managed destination is not a regular file: $path"
  local observed=''
  observed=$(sed -n '1,$p' "$path") || install_common_die "unable to read managed destination: $path"
  [[ "$observed" == "$desired" || ( -n "$source_default" && "$observed" == "$source_default" ) ]] || install_common_die "existing policy differs and will not be overwritten: $path"
}

SOURCE_HOSTS='# Static table lookup for hostnames.
# See hosts(5) for details.
127.0.0.1        localhost
::1              localhost'
assert_text_destination "$ROOT/etc/hostname" "$HOSTNAME_CONTENT" alarm
assert_text_destination "$ROOT/etc/hosts" "$HOSTS_CONTENT" "$SOURCE_HOSTS"
assert_text_destination "$ROOT/etc/locale.conf" "$LOCALE_CONTENT" 'LANG=C'
assert_text_destination "$ROOT/etc/vconsole.conf" "$VCONSOLE_CONTENT"
assert_text_destination "$ROOT/etc/ssh/sshd_config.d/10-uconsole.conf" "$SSHD_CONTENT"
assert_text_destination "$ROOT/etc/sudoers.d/10-uconsole-admin" "$(sed -n '1,$p' "$SUDOERS_CONFIG")"
assert_text_destination "$ROOT/etc/NetworkManager/conf.d/10-uconsole.conf" "$(sed -n '1,$p' "$NM_CONFIG")"
assert_text_destination "$ROOT/etc/modprobe.d/90-uconsole-regdom.conf" "$REGDOM_CONTENT"

CONFIG_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection"
if [[ -e "$CONFIG_STATE" ]]; then
  install_common_require_file 'base-system configuration state' "$CONFIG_STATE"
  for expected_pair in \
    "admin_user=$ADMIN_USER" \
    "hostname=$HOSTNAME" \
    "timezone=$TIMEZONE" \
    "locale=$LOCALE" \
    "keymap=$KEYMAP" \
    "reg_domain=$REG_DOMAIN" \
    "ssh_key_fingerprint=$SSH_KEY_FINGERPRINT" \
    "wifi_preseed=$WIFI_PRESEED" \
    'network_manager=NetworkManager'; do
    grep -Fqx "$expected_pair" "$CONFIG_STATE" || install_common_die "existing base-system selection differs: ${expected_pair%%=*}"
  done
fi

AUTHORIZED_KEYS="$ROOT$ADMIN_HOME/.ssh/authorized_keys"
if [[ -e "$AUTHORIZED_KEYS" ]]; then
  install_common_require_file 'existing authorized_keys' "$AUTHORIZED_KEYS"
  cmp -s "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS" || install_common_die 'existing authorized_keys differs from the requested public key'
fi
WIFI_DEST="$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection"
if [[ "$WIFI_PRESEED" == yes && -e "$WIFI_DEST" ]]; then
  install_common_require_file 'existing bootstrap Wi-Fi keyfile' "$WIFI_DEST"
  cmp -s "$WIFI_KEYFILE" "$WIFI_DEST" || install_common_die 'existing bootstrap Wi-Fi keyfile differs from the requested private input'
elif [[ "$WIFI_PRESEED" == no && -e "$WIFI_DEST" ]]; then
  install_common_die 'bootstrap Wi-Fi keyfile exists but --wifi-keyfile was omitted'
fi
if [[ ! -e "$CONFIG_STATE" ]]; then
  EXISTING_CONNECTION=''
  CONNECTION_DIR="$ROOT/etc/NetworkManager/system-connections"
  if [[ -d "$CONNECTION_DIR" ]]; then
    EXISTING_CONNECTION=$(find "$CONNECTION_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.nmconnection' -print -quit) || install_common_die 'unable to inspect existing NetworkManager connections'
  elif [[ -e "$CONNECTION_DIR" ]]; then
    install_common_die "NetworkManager connection path is not a directory: $CONNECTION_DIR"
  fi
  [[ -z "$EXISTING_CONNECTION" || "$EXISTING_CONNECTION" == "$WIFI_DEST" ]] || install_common_die "unexpected pre-existing NetworkManager connection: $EXISTING_CONNECTION"
  EXISTING_HOST_KEY=$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)
  [[ -z "$EXISTING_HOST_KEY" ]] || install_common_die 'pre-existing SSH host keys would be cloned; use a fresh root or explicit recovery procedure'
fi

printf '%s\n' \
  '[PASS] lower-layer state      exact hardware and base-system packages present' \
  "[PASS] admin access          user=$ADMIN_USER uid=$ADMIN_UID ssh=$SSH_KEY_FINGERPRINT" \
  "[PASS] local recovery       private yescrypt/SHA-512 hash validated; value not printed" \
  "[PASS] locale/time          $LOCALE $KEYMAP $TIMEZONE" \
  "[PASS] radio policy         regulatory domain $REG_DOMAIN" \
  "[PASS] network policy       NetworkManager + systemd-resolved; Wi-Fi preseed=$WIFI_PRESEED validation=$WIFI_VALIDATION" \
  '[PASS] SSH policy           key-only; root/password/keyboard-interactive login disabled' \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  "Hostname: $HOSTNAME" \
  'Default accounts: root locked; alarm locked unless selected as admin' \
  'Services enabled: NetworkManager sshd systemd-resolved bluetooth' \
  'Services disabled: systemd-networkd and its activation sockets/wait-online' \
  ''

if [[ "$ACTION" == plan ]]; then
  printf '%s\n' \
    'Plan complete. No account, password hash, key, package, service or policy file was changed.' \
    'Secret values were validated locally and were not printed or recorded.'
  exit 0
fi

if [[ "$CHROOT_COMMAND" == */* ]]; then
  [[ -x "$CHROOT_COMMAND" ]] || install_common_die "chroot command is not executable: $CHROOT_COMMAND"
else
  command -v "$CHROOT_COMMAND" >/dev/null 2>&1 || install_common_die "chroot command not found: $CHROOT_COMMAND"
fi
[[ -w "$ROOT" ]] || install_common_die "offline root must be writable: $ROOT"

for required_package in 'networkmanager 1.58.1-1' 'sudo 1.9.17.p2-6' 'bluez 5.87-2' 'bluez-utils 5.87-2' 'openssh 10.4p1-3'; do
  package_name=${required_package%% *}
  observed=$("$CHROOT_COMMAND" "$ROOT" pacman -Q "$package_name") || install_common_fail "required installed package is missing: $package_name"
  [[ "$observed" == "$required_package" ]] || install_common_fail "required installed package differs: $observed"
done

if [[ -z "$ADMIN_PASSWD_COUNT" ]]; then
  "$CHROOT_COMMAND" "$ROOT" useradd --create-home --groups wheel --shell /bin/bash "$ADMIN_USER" || install_common_fail 'unable to create admin account'
fi
"$CHROOT_COMMAND" "$ROOT" usermod --append --groups wheel "$ADMIN_USER" || install_common_fail 'unable to add admin account to wheel'
PASSWORD_PIPE_STATUS=0
printf '%s:%s\n' "$ADMIN_USER" "$CONSOLE_PASSWORD_HASH" | "$CHROOT_COMMAND" "$ROOT" chpasswd --encrypted
PASSWORD_PIPE_STATUS=(${PIPESTATUS[@]})
[[ ${PASSWORD_PIPE_STATUS[0]} -eq 0 && ${PASSWORD_PIPE_STATUS[1]} -eq 0 ]] || install_common_fail 'unable to set encrypted local-console recovery password'

account_locked() {
  local account=$1
  awk -F ':' -v wanted="$account" '$1 == wanted { found=1; if ($2 ~ /^!|^\*/) exit 0; exit 1 } END { if (!found) exit 2 }' "$ROOT/etc/shadow"
}
if ! account_locked root; then "$CHROOT_COMMAND" "$ROOT" passwd --lock root || install_common_fail 'unable to lock root account'; fi
if [[ "$ADMIN_USER" != alarm ]] && ! account_locked alarm; then "$CHROOT_COMMAND" "$ROOT" passwd --lock alarm || install_common_fail 'unable to lock source alarm account'; fi

ADMIN_ENTRY=$(awk -F ':' -v wanted="$ADMIN_USER" '$1 == wanted { count++; uid=$3; gid=$4; home=$6 } END { if (count == 1) print uid ":" gid ":" home; else exit 1 }' "$ROOT/etc/passwd") || install_common_fail 'unable to query configured admin account'
IFS=':' read -r ADMIN_UID ADMIN_GID ADMIN_HOME <<< "$ADMIN_ENTRY"
mkdir -p "$ROOT$ADMIN_HOME/.ssh" || install_common_fail 'unable to create admin SSH directory'
chmod 0700 "$ROOT$ADMIN_HOME/.ssh" || install_common_fail 'unable to set admin SSH directory mode'
install -m 0600 "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS" || install_common_fail 'unable to install authorized key'
"$CHROOT_COMMAND" "$ROOT" chown -R "$ADMIN_UID:$ADMIN_GID" "$ADMIN_HOME/.ssh" || install_common_fail 'unable to set SSH key ownership'

backup_source_file() {
  local path=$1
  local backup="${path}.pre-uconsole"
  if [[ -e "$path" && ! -e "$backup" ]]; then cp -a -- "$path" "$backup" || install_common_fail "unable to back up source policy: $path"; fi
}
backup_source_file "$ROOT/etc/hostname"
backup_source_file "$ROOT/etc/hosts"
backup_source_file "$ROOT/etc/locale.conf"

install_text() {
  local content=$1
  local mode=$2
  local destination=$3
  local parent=${destination%/*}
  mkdir -p "$parent" || return 1
  local temporary="$parent/.${destination##*/}.uconsole.$$"
  printf '%s\n' "$content" > "$temporary" || return 1
  chmod "$mode" "$temporary" || return 1
  mv "$temporary" "$destination"
}
install_text "$HOSTNAME_CONTENT" 0644 "$ROOT/etc/hostname" || install_common_fail 'unable to install hostname'
install_text "$HOSTS_CONTENT" 0644 "$ROOT/etc/hosts" || install_common_fail 'unable to install hosts'
install_text "$LOCALE_CONTENT" 0644 "$ROOT/etc/locale.conf" || install_common_fail 'unable to install locale.conf'
install_text "$VCONSOLE_CONTENT" 0644 "$ROOT/etc/vconsole.conf" || install_common_fail 'unable to install vconsole.conf'
install_text "$SSHD_CONTENT" 0644 "$ROOT/etc/ssh/sshd_config.d/10-uconsole.conf" || install_common_fail 'unable to install sshd policy'
install_text "$(sed -n '1,$p' "$SUDOERS_CONFIG")" 0440 "$ROOT/etc/sudoers.d/10-uconsole-admin" || install_common_fail 'unable to install sudo policy'
install_text "$(sed -n '1,$p' "$NM_CONFIG")" 0644 "$ROOT/etc/NetworkManager/conf.d/10-uconsole.conf" || install_common_fail 'unable to install NetworkManager policy'
install_text "$REGDOM_CONTENT" 0644 "$ROOT/etc/modprobe.d/90-uconsole-regdom.conf" || install_common_fail 'unable to install regulatory-domain policy'
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOT/etc/localtime" || install_common_fail 'unable to install timezone symlink'

LOCALE_TMP="$ROOT/etc/.locale.gen.uconsole.$$"
sed 's/^#en_US\.UTF-8 UTF-8  $/en_US.UTF-8 UTF-8  /' "$ROOT/etc/locale.gen" > "$LOCALE_TMP" || install_common_fail 'unable to stage locale.gen'
chmod 0644 "$LOCALE_TMP" || install_common_fail 'unable to set locale.gen mode'
mv "$LOCALE_TMP" "$ROOT/etc/locale.gen" || install_common_fail 'unable to publish locale.gen'
"$CHROOT_COMMAND" "$ROOT" locale-gen || install_common_fail 'locale generation failed'

mkdir -p "$ROOT/etc/NetworkManager/system-connections" || install_common_fail 'unable to create NetworkManager connection directory'
chmod 0700 "$ROOT/etc/NetworkManager/system-connections" || install_common_fail 'unable to secure NetworkManager connection directory'
if [[ "$WIFI_PRESEED" == yes ]]; then
  install -m 0600 "$WIFI_KEYFILE" "$WIFI_DEST" || install_common_fail 'unable to install private bootstrap Wi-Fi keyfile'
fi

"$CHROOT_COMMAND" "$ROOT" visudo --check --file /etc/sudoers || install_common_fail 'sudo policy validation failed'
"$CHROOT_COMMAND" "$ROOT" systemctl disable \
  systemd-networkd.service \
  systemd-networkd.socket \
  systemd-networkd-wait-online.service \
  systemd-networkd-resolve-hook.socket \
  systemd-networkd-varlink.socket \
  systemd-networkd-varlink-metrics.socket || install_common_fail 'unable to disable systemd-networkd activation paths'
"$CHROOT_COMMAND" "$ROOT" systemctl enable NetworkManager.service sshd.service systemd-resolved.service bluetooth.service || install_common_fail 'unable to enable required first-boot services'

for enabled_unit in NetworkManager.service sshd.service systemd-resolved.service bluetooth.service; do
  UNIT_STATE=$("$CHROOT_COMMAND" "$ROOT" systemctl is-enabled "$enabled_unit" 2>&1)
  [[ "$UNIT_STATE" == enabled ]] || install_common_fail "required unit is not enabled: $enabled_unit ($UNIT_STATE)"
done
for disabled_unit in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service; do
  UNIT_STATE=''
  "$CHROOT_COMMAND" "$ROOT" systemctl is-enabled "$disabled_unit" >/dev/null 2>&1
  UNIT_STATUS=$?
  ((UNIT_STATUS != 0)) || install_common_fail "conflicting unit remains enabled: $disabled_unit"
done

mkdir -p "$ROOT/var/lib/uconsole-omarchy-arm64" || install_common_fail 'unable to create configuration state directory'
STATE_TMP="$ROOT/var/lib/uconsole-omarchy-arm64/.base-system-selection.$$"
{
  printf 'admin_user=%s\n' "$ADMIN_USER"
  printf 'hostname=%s\n' "$HOSTNAME"
  printf 'timezone=%s\n' "$TIMEZONE"
  printf 'locale=%s\n' "$LOCALE"
  printf 'keymap=%s\n' "$KEYMAP"
  printf 'reg_domain=%s\n' "$REG_DOMAIN"
  printf 'ssh_key_fingerprint=%s\n' "$SSH_KEY_FINGERPRINT"
  printf 'wifi_preseed=%s\n' "$WIFI_PRESEED"
  printf 'network_manager=NetworkManager\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage base-system selection state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set base-system state mode'
mv "$STATE_TMP" "$CONFIG_STATE" || install_common_fail 'unable to publish base-system selection state'

printf '%s\n' \
  '[PASS] admin account          SSH key + local-console recovery configured' \
  '[PASS] default accounts       root and non-admin alarm accounts locked' \
  '[PASS] SSH policy             key-only configuration installed' \
  '[PASS] network ownership      NetworkManager enabled; networkd disabled' \
  '[PASS] Bluetooth              bluetooth.service enabled' \
  '[PASS] locale/time/radio      generated and persisted' \
  '[PASS] selection state        no secret values recorded' \
  'Base system configured in the offline root. No physical device was opened.'
