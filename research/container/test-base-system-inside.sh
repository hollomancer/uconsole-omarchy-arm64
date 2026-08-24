#!/usr/bin/env bash

# Clone the retained hardware root, apply the exact base-system package and
# policy transactions with synthetic credentials, and inspect effective state.

set -u
set -o pipefail
umask 077

SOURCE_ROOT=/source/root
ROOT=/output/root
CHROOT=/usr/bin/chroot
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

[[ -f "$SOURCE_ROOT/etc/os-release" && -d "$SOURCE_ROOT/var/lib/pacman/local" ]] || fail 'source hardware root is missing'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'destination Linux volume must be empty'
mkdir "$ROOT" || fail 'unable to create destination root'
bsdtar -cpf - --acls --xattrs --no-fflags --numeric-owner -C "$SOURCE_ROOT" . | \
  bsdtar -xpf - --acls --xattrs --no-fflags --numeric-owner -C "$ROOT"
COPY_STATUS=(${PIPESTATUS[@]})
[[ ${COPY_STATUS[0]} -eq 0 && ${COPY_STATUS[1]} -eq 0 ]] || fail "root clone failed: create=${COPY_STATUS[0]} extract=${COPY_STATUS[1]}"

mount --bind "$ROOT" "$ROOT" || fail 'unable to make destination root a mount point'
ROOT_MOUNTED=1
mount --make-private "$ROOT" || fail 'unable to make destination root private'
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" || fail 'unable to create chroot mount points'
mount --rbind /dev "$ROOT/dev" || fail 'unable to bind /dev'
DEV_MOUNTED=1
mount --make-rslave "$ROOT/dev" || fail 'unable to isolate target /dev'
mount -t proc proc "$ROOT/proc" || fail 'unable to mount target /proc'
PROC_MOUNTED=1
mount --rbind /sys "$ROOT/sys" || fail 'unable to bind /sys'
SYS_MOUNTED=1
mount --make-rslave "$ROOT/sys" || fail 'unable to isolate target /sys'
mount --rbind /run "$ROOT/run" || fail 'unable to bind /run'
RUN_MOUNTED=1
mount --make-rslave "$ROOT/run" || fail 'unable to isolate target /run'

/repo/scripts/install-base-system-packages.sh \
  --apply --root "$ROOT" --package-dir /input --chroot-command "$CHROOT" || fail 'base-system package transaction failed'

mkdir -p /work || fail 'unable to create synthetic credential workspace'
"$CHROOT" "$ROOT" ssh-keygen -q -t ed25519 -N '' -f /var/tmp/uconsole-integration-admin || fail 'unable to generate synthetic SSH key in target'
SYNTHETIC_PUBLIC_KEY="$ROOT/var/tmp/uconsole-integration-admin.pub"
openssl passwd -6 -salt integration-salt integration-only > /work/integration-password.hash || fail 'unable to generate synthetic console hash'
chmod 0600 /work/integration-password.hash || fail 'unable to secure synthetic console hash'
cat > /work/integration-wifi.nmconnection <<'WIFI'
[connection]
id=integration-wifi
uuid=11111111-2222-4333-8444-555555555555
type=wifi
autoconnect=true

[wifi]
ssid=integration-network

[wifi-security]
key-mgmt=wpa-psk
psk=integration-only-psk

[ipv4]
method=auto

[ipv6]
method=auto
WIFI
chmod 0600 /work/integration-wifi.nmconnection || fail 'unable to secure synthetic Wi-Fi keyfile'

CONFIG_ARGS=(
  --root "$ROOT"
  --admin-user integration
  --ssh-public-key "$SYNTHETIC_PUBLIC_KEY"
  --console-password-hash-file /work/integration-password.hash
  --wifi-keyfile /work/integration-wifi.nmconnection
  --reg-domain US
  --hostname uconsole-integration
  --timezone UTC
  --chroot-command "$CHROOT"
)
/repo/scripts/configure-base-system.sh --plan "${CONFIG_ARGS[@]}" || fail 'base-system configuration plan failed'
/repo/scripts/configure-base-system.sh --apply "${CONFIG_ARGS[@]}" || fail 'base-system configuration apply failed'
/repo/scripts/configure-base-system.sh --apply "${CONFIG_ARGS[@]}" || fail 'base-system configuration idempotent re-run failed'

for package in 'networkmanager 1.58.1-1' 'sudo 1.9.17.p2-6' 'bluez 5.87-2' 'bluez-utils 5.87-2'; do
  name=${package%% *}
  [[ $("$CHROOT" "$ROOT" pacman -Q "$name") == "$package" ]] || fail "installed package differs: $name"
done
for enabled_unit in NetworkManager.service sshd.service systemd-resolved.service bluetooth.service; do
  [[ $("$CHROOT" "$ROOT" systemctl is-enabled "$enabled_unit") == enabled ]] || fail "required unit is not enabled: $enabled_unit"
done
for disabled_unit in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service; do
  "$CHROOT" "$ROOT" systemctl is-enabled "$disabled_unit" >/dev/null 2>&1
  unit_status=$?
  ((unit_status != 0)) || fail "conflicting unit remains enabled: $disabled_unit"
done

awk -F ':' '$1=="root" { found=1; if ($2 !~ /^!/) exit 1 } END { exit !found }' "$ROOT/etc/shadow" || fail 'root account is not locked'
awk -F ':' '$1=="alarm" { found=1; if ($2 !~ /^!/) exit 1 } END { exit !found }' "$ROOT/etc/shadow" || fail 'source alarm account is not locked'
awk -F ':' '$1=="integration" { found=1; if ($2 !~ /^\$6\$/) exit 1 } END { exit !found }' "$ROOT/etc/shadow" || fail 'integration console account lacks encrypted recovery hash'
grep -Eq '^wheel:[^:]*:[^:]*:.*(^|,)integration(,|$)' "$ROOT/etc/group" || fail 'integration account is not in wheel'
cmp -s "$SYNTHETIC_PUBLIC_KEY" "$ROOT/home/integration/.ssh/authorized_keys" || fail 'installed authorized key differs'
[[ $(stat -c '%a' "$ROOT/home/integration/.ssh/authorized_keys") == 600 ]] || fail 'authorized_keys mode differs'
[[ $(stat -c '%a' "$ROOT/etc/NetworkManager/system-connections/uconsole-bootstrap.nmconnection") == 600 ]] || fail 'Wi-Fi keyfile mode differs'
grep -Fqx 'wifi_preseed=yes' "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" || fail 'Wi-Fi selection state differs'
if grep -FRq 'integration-only-psk' "$ROOT/var/lib/uconsole-omarchy-arm64"; then fail 'Wi-Fi secret leaked into public selection state'; fi

"$CHROOT" "$ROOT" ssh-keygen -q -t ed25519 -N '' -f /run/uconsole-integration-host-key || fail 'unable to create transient sshd validation key'
SSHD_EFFECTIVE=$("$CHROOT" "$ROOT" sshd -T -h /run/uconsole-integration-host-key -C user=integration,host=localhost,addr=127.0.0.1) || fail 'effective sshd configuration validation failed'
rm -f -- "$ROOT/run/uconsole-integration-host-key" "$ROOT/run/uconsole-integration-host-key.pub" || fail 'unable to remove transient sshd validation key'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi 'passwordauthentication no' || fail 'effective SSH password policy differs'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi 'kbdinteractiveauthentication no' || fail 'effective SSH keyboard-interactive policy differs'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi 'permitrootlogin no' || fail 'effective SSH root policy differs'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi 'authenticationmethods publickey' || fail 'effective SSH authentication method differs'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi 'allowusers integration' || fail 'effective SSH allowlist differs'

NM_EFFECTIVE=$("$CHROOT" "$ROOT" NetworkManager --print-config) || fail 'NetworkManager effective config validation failed'
printf '%s\n' "$NM_EFFECTIVE" | grep -Fq 'dns=systemd-resolved' || fail 'effective NetworkManager DNS policy differs'
"$CHROOT" "$ROOT" locale -a | grep -Fqx 'en_US.utf8' || fail 'generated locale is missing'
rm -f -- "$ROOT/var/tmp/uconsole-integration-admin" "$ROOT/var/tmp/uconsole-integration-admin.pub" || fail 'unable to remove synthetic admin keypair'
[[ ! -e "$SOURCE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages" ]] || fail 'source retained hardware root was mutated'
[[ ! -e "$SOURCE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'source retained hardware configuration was mutated'
[[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'SSH host keys were baked into the image root'

printf '[PASS] base-system ARM64 integration packages, accounts, services, locale and effective SSH/NM policy verified\n'
printf '[PASS] source boundary retained hardware root unchanged; synthetic configured clone remains in destination volume\n'
