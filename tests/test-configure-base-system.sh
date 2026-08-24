#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=''
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve test directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi
CONFIGURER="$REPO_ROOT/scripts/configure-base-system.sh"
FAKE_CHROOT="$TEST_DIR/helpers/fake-base-system-chroot.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-base-config-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-base-config-test.*|/private/tmp/uconsole-base-config-test.*|/var/folders/*/T/uconsole-base-config-test.*|/private/var/folders/*/T/uconsole-base-config-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

ROOT="$TEST_TMP/root"
mkdir -p \
  "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/sudoers.d" "$ROOT/etc/NetworkManager" \
  "$ROOT/etc/modprobe.d" "$ROOT/usr/share/zoneinfo" "$ROOT/var/lib/pacman/local" \
  "$ROOT/var/lib/uconsole-omarchy-arm64" "$ROOT/home/alarm" "$ROOT/boot"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
printf 'alarm\n' > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<'HOSTS'
# Static table lookup for hostnames.
# See hosts(5) for details.
127.0.0.1        localhost
::1              localhost
HOSTS
printf 'LANG=C\n' > "$ROOT/etc/locale.conf"
printf '#en_US.UTF-8 UTF-8  \n' > "$ROOT/etc/locale.gen"
printf 'fixture timezone\n' > "$ROOT/usr/share/zoneinfo/UTC"
printf 'root:x:0:0:root:/root:/usr/bin/bash\nalarm:x:1000:1000:Alarm:/home/alarm:/bin/bash\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\nwheel:x:998:alarm\nalarm:x:1000:\n' > "$ROOT/etc/group"
printf 'root:root-source-hash:20000:0:99999:7:::\nalarm:alarm-source-hash:20000:0:99999:7:::\n' > "$ROOT/etc/shadow"
chmod 0600 "$ROOT/etc/shadow"
printf '# fixture sudoers\n@includedir /etc/sudoers.d\n' > "$ROOT/etc/sudoers"
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" <<'STATE'
kernel_package=linux-rpi-16k
kernel_version=6.18.45-1
kernel_release=6.18.45-1-rpi-16k
board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a
STATE
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages" <<'STATE'
networkmanager=1.58.1-1
sudo=1.9.17.p2-6
bluez=5.87-2
bluez-utils=5.87-2
STATE
printf '%s\n' \
  'networkmanager 1.58.1-1' 'sudo 1.9.17.p2-6' 'bluez 5.87-2' \
  'bluez-utils 5.87-2' 'openssh 10.4p1-3' > "$ROOT/var/lib/fake-base-packages"

ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/admin-key"
SSH_PUBLIC_KEY="$TEST_TMP/admin-key.pub"
PASSWORD_HASH="$TEST_TMP/password.hash"
printf '%s\n' '$6$fixture-salt$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' > "$PASSWORD_HASH"
chmod 0600 "$PASSWORD_HASH"
WIFI_KEYFILE="$TEST_TMP/wifi.nmconnection"
cat > "$WIFI_KEYFILE" <<'WIFI'
[connection]
id=fixture-wifi
uuid=11111111-2222-4333-8444-555555555555
type=wifi
autoconnect=true

[wifi]
ssid=fixture-network

[wifi-security]
key-mgmt=wpa-psk
psk=fixture-secret

[ipv4]
method=auto
WIFI
chmod 0600 "$WIFI_KEYFILE"

ARGS=(
  --root "$ROOT" --admin-user codex --ssh-public-key "$SSH_PUBLIC_KEY"
  --console-password-hash-file "$PASSWORD_HASH" --wifi-keyfile "$WIFI_KEYFILE"
  --reg-domain US --hostname uconsole --timezone UTC --chroot-command "$FAKE_CHROOT"
)
LOG="$TEST_TMP/chroot.log"
: > "$LOG"

PLAN_OUTPUT=$(FAKE_BASE_CHROOT_LOG="$LOG" "$CONFIGURER" "${ARGS[@]}" --plan) || { printf 'Expected base config plan to pass\n' >&2; exit 1; }
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'Secret values were validated locally and were not printed or recorded.' || { printf 'Secret boundary missing\n' >&2; exit 1; }
[[ ! -e "$ROOT/etc/ssh/sshd_config.d/10-uconsole.conf" ]] || { printf 'Plan wrote SSH config\n' >&2; exit 1; }
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || { printf 'Plan wrote state\n' >&2; exit 1; }

FAKE_BASE_CHROOT_LOG="$LOG" "$CONFIGURER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected base config apply to pass\n' >&2; exit 1; }
grep -Eq '^wheel:[^:]*:[^:]*:.*(^|,)codex(,|$)' "$ROOT/etc/group" || { printf 'Admin not added to wheel\n' >&2; exit 1; }
awk -F ':' '$1=="root" { found=1; valid=($2 ~ /^!/) } END { exit !(found && valid) }' "$ROOT/etc/shadow" || { printf 'Root not locked\n' >&2; exit 1; }
awk -F ':' '$1=="alarm" { found=1; valid=($2 ~ /^!/) } END { exit !(found && valid) }' "$ROOT/etc/shadow" || { printf 'Alarm not locked\n' >&2; exit 1; }
awk -F ':' '$1=="codex" { found=1; valid=($2 ~ /^\$6\$/) } END { exit !(found && valid) }' "$ROOT/etc/shadow" || { printf 'Admin recovery hash not installed\n' >&2; exit 1; }
cmp -s "$SSH_PUBLIC_KEY" "$ROOT/home/codex/.ssh/authorized_keys" || { printf 'Authorized key differs\n' >&2; exit 1; }
cmp -s "$WIFI_KEYFILE" "$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection" || { printf 'Wi-Fi keyfile differs\n' >&2; exit 1; }
if stat -c '%a' "$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection" >/dev/null 2>&1; then
  WIFI_DEST_MODE=$(stat -c '%a' "$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection")
else
  WIFI_DEST_MODE=$(stat -f '%Lp' "$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection")
fi
[[ "$WIFI_DEST_MODE" == 600 ]] || { printf 'Wi-Fi mode differs\n' >&2; exit 1; }
grep -Fqx 'AllowUsers codex' "$ROOT/etc/ssh/sshd_config.d/10-uconsole.conf" || { printf 'SSH allowlist differs\n' >&2; exit 1; }
grep -Fqx 'wifi_preseed=yes' "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" || { printf 'Wi-Fi state missing\n' >&2; exit 1; }
if grep -Fq 'fixture-secret' "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" "$LOG"; then printf 'Secret leaked into state or log\n' >&2; exit 1; fi
for unit in NetworkManager.service sshd.service systemd-resolved.service bluetooth.service; do
  [[ -f "$ROOT/var/lib/fake-systemctl/$unit" ]] || { printf 'Required unit not enabled: %s\n' "$unit" >&2; exit 1; }
done

USERADD_COUNT=$(grep -Fc 'useradd ' "$LOG")
FAKE_BASE_CHROOT_LOG="$LOG" "$CONFIGURER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected idempotent base config re-run to pass\n' >&2; exit 1; }
[[ $(grep -Fc 'useradd ' "$LOG") -eq $USERADD_COUNT ]] || { printf 'Idempotent re-run recreated admin\n' >&2; exit 1; }

chmod 0644 "$PASSWORD_HASH"
MODE_STATUS=0
FAKE_BASE_CHROOT_LOG="$LOG" "$CONFIGURER" "${ARGS[@]}" --plan >/dev/null 2>&1
MODE_STATUS=$?
[[ $MODE_STATUS -eq 2 ]] || { printf 'Expected public password-hash file rejection\n' >&2; exit 1; }

PLAIN_STATUS=0
FAKE_BASE_CHROOT_LOG="$LOG" "$CONFIGURER" "${ARGS[@]}" --password secret --plan >/dev/null 2>&1
PLAIN_STATUS=$?
[[ $PLAIN_STATUS -eq 2 ]] || { printf 'Expected plaintext password argument rejection\n' >&2; exit 1; }

printf 'configure-base-system fixture tests: PASS\n'
