#!/usr/bin/env bash

# Verify completed base configuration through the production image-plan gate
# plus effective service policy. The only target-root write is a transient SSH
# key in a tmpfs mounted over /run.

set -u
set -o pipefail

ROOT=${UCONSOLE_INSPECTION_ROOT:-/source/root}
if [[ "$ROOT" != /source/root && "$ROOT" != /restore/root && ! "$ROOT" =~ ^/work/phase1-image-inspect\.[A-Za-z0-9]+$ ]]; then
  printf '[FAIL] unsafe inspection root\n' >&2
  exit 1
fi
STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
BASE_STATE="$STATE_DIR/base-system-selection"
TRANSIENT_KEY=/run/uconsole-phase1-inspection-host-key
DEV_MOUNTED=0
PROC_MOUNTED=0
SYS_MOUNTED=0

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

cleanup_mounts() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $SYS_MOUNTED -eq 1 ]]; then umount -R "$ROOT/sys" || status=1; fi
  if [[ $PROC_MOUNTED -eq 1 ]]; then umount "$ROOT/proc" || status=1; fi
  if [[ $DEV_MOUNTED -eq 1 ]]; then umount -R "$ROOT/dev" || status=1; fi
  exit "$status"
}
trap cleanup_mounts EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

state_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$BASE_STATE"
}

[[ -f "$BASE_STATE" && ! -L "$BASE_STATE" ]] || fail 'completed base-system selection state is missing or unsafe'
for absent_state in hyprland-selection omarchy-shell-selection; do
  [[ ! -e "$STATE_DIR/$absent_state" ]] || fail "desktop state is unexpectedly present: $absent_state"
done

/repo/scripts/build-image.sh --plan \
  --root-tree "$ROOT" \
  --output /run/uconsole-phase1-inspection.img \
  --disk-id a1b2c3d4 \
  --boot-id A1B2C3D4 \
  --root-uuid 11111111-2222-4333-8444-555555555555 \
  --source-date-epoch 1787544000 || fail 'production image-plan configuration gate failed'
[[ ! -e /run/uconsole-phase1-inspection.img && ! -e /run/uconsole-phase1-inspection.img.manifest.json ]] || fail 'image plan created output'

mount --rbind /dev "$ROOT/dev" || fail 'unable to bind transient /dev for inspection'
DEV_MOUNTED=1
mount --make-rslave "$ROOT/dev" || fail 'unable to isolate transient inspection /dev'
mount -t proc proc "$ROOT/proc" || fail 'unable to mount transient /proc for inspection'
PROC_MOUNTED=1
mount --rbind /sys "$ROOT/sys" || fail 'unable to bind transient /sys for inspection'
SYS_MOUNTED=1
mount --make-rslave "$ROOT/sys" || fail 'unable to isolate transient inspection /sys'

ADMIN_USER=$(state_field admin_user) || fail 'unable to read configured admin'
WIFI_PRESEED=$(state_field wifi_preseed) || fail 'unable to read configured Wi-Fi policy'
SSH_FINGERPRINT=$(state_field ssh_key_fingerprint) || fail 'unable to read configured SSH fingerprint'
ADMIN_HOME=$(awk -F ':' -v wanted="$ADMIN_USER" '$1 == wanted { count++; home=$6 } END { if (count == 1) print home; else exit 1 }' "$ROOT/etc/passwd") || fail 'configured admin entry differs'
AUTHORIZED_KEYS="$ROOT$ADMIN_HOME/.ssh/authorized_keys"
OBSERVED_FINGERPRINT=$(chroot "$ROOT" ssh-keygen -lf "$ADMIN_HOME/.ssh/authorized_keys" -E sha256 | awk 'NF >= 2 {print $2; exit}') || fail 'unable to inspect authorized-key fingerprint'
[[ "$OBSERVED_FINGERPRINT" == "$SSH_FINGERPRINT" ]] || fail 'authorized key fingerprint differs from selection state'

chroot "$ROOT" ssh-keygen -q -t ed25519 -N '' -f "$TRANSIENT_KEY" || fail 'unable to create transient inspection host key'
SSHD_EFFECTIVE=$(chroot "$ROOT" sshd -T -h "$TRANSIENT_KEY" -C "user=$ADMIN_USER,host=localhost,addr=127.0.0.1") || fail 'effective sshd policy validation failed'
rm -f -- "$ROOT$TRANSIENT_KEY" "$ROOT${TRANSIENT_KEY}.pub" || fail 'unable to remove transient inspection host key'
for expected_policy in \
  'passwordauthentication no' \
  'kbdinteractiveauthentication no' \
  'permitrootlogin no' \
  'authenticationmethods publickey' \
  "allowusers $ADMIN_USER"; do
  printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fqxi "$expected_policy" || fail "effective SSH policy differs: $expected_policy"
done

NM_EFFECTIVE=$(chroot "$ROOT" NetworkManager --print-config) || fail 'effective NetworkManager policy validation failed'
printf '%s\n' "$NM_EFFECTIVE" | grep -Fq 'dns=systemd-resolved' || fail 'effective NetworkManager DNS policy differs'
for enabled_unit in NetworkManager.service sshd.service systemd-resolved.service bluetooth.service; do
  [[ $(chroot "$ROOT" systemctl is-enabled "$enabled_unit") == enabled ]] || fail "required unit is not enabled: $enabled_unit"
done
for disabled_unit in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service; do
  chroot "$ROOT" systemctl is-enabled "$disabled_unit" >/dev/null 2>&1
  unit_status=$?
  ((unit_status != 0)) || fail "conflicting unit remains enabled: $disabled_unit"
done
chroot "$ROOT" locale -a | grep -Fqx 'en_US.utf8' || fail 'configured locale is missing'
[[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" ]] || fail 'persistent SSH host key was found'

printf '[PASS] production image gate exact hardware/base state, accounts, policy and boot files\n'
printf '[PASS] effective SSH         key-only admin=%s fingerprint=%s\n' "$ADMIN_USER" "$SSH_FINGERPRINT"
printf '[PASS] effective services    NetworkManager/resolved/sshd/Bluetooth; networkd disabled\n'
printf '[PASS] configured locale     en_US.utf8; Wi-Fi preseed=%s\n' "$WIFI_PRESEED"
printf '[PASS] identity boundary     no persistent SSH host key and no image created\n'
printf '[PASS] base state digest     %s\n' "$(sha256sum "$BASE_STATE" | awk '{print $1}')"
