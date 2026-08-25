#!/usr/bin/env bash

# Exercise image-builder validation and destructive boundaries without creating
# an image, loop device, filesystem or mount.

set -u
set -o pipefail

TEST_DIR=''
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi
BUILDER="$REPO_ROOT/scripts/build-image.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-image-plan-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-image-plan-test.*|/private/tmp/uconsole-image-plan-test.*|/var/folders/*/T/uconsole-image-plan-test.*|/private/var/folders/*/T/uconsole-image-plan-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

ROOT="$TEST_TMP/root"
OUTPUT_DIR="$TEST_TMP/output"
mkdir -p \
  "$ROOT/etc" \
  "$ROOT/etc/NetworkManager/conf.d" \
  "$ROOT/etc/NetworkManager/system-connections" \
  "$ROOT/etc/modprobe.d" \
  "$ROOT/etc/ssh/sshd_config.d" \
  "$ROOT/boot/overlays" \
  "$ROOT/home/fixture/.ssh" \
  "$ROOT/usr/share/zoneinfo" \
  "$ROOT/var/lib/pacman/local" \
  "$ROOT/var/lib/uconsole-omarchy-arm64" \
  "$OUTPUT_DIR"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
printf '%s\n' '# fixture fstab replaced only in image' > "$ROOT/etc/fstab"
printf '%s\n' 'root=/dev/mmcblk0p2 rw' > "$ROOT/boot/cmdline.txt"
cat > "$ROOT/boot/config.txt" <<'CONFIG'
arm_64bit=1
dtoverlay=vc4-kms-v3d
# BEGIN uconsole-omarchy-arm64 hardware include
include uconsole-cm5.txt
# END uconsole-omarchy-arm64 hardware include
CONFIG
for boot_file in \
  kernel8.img \
  initramfs-linux.img \
  start4.elf \
  fixup4.dat \
  bcm2712-rpi-cm5-cm5io.dtb \
  uconsole-cm5.txt \
  overlays/vc4-kms-v3d.dtbo \
  overlays/uconsole-cm5-base.dtbo \
  overlays/uconsole-audio-cm5.dtbo; do
  printf 'fixture: %s\n' "$boot_file" > "$ROOT/boot/$boot_file"
done
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" <<'STATE'
kernel_package=linux-rpi-16k
kernel_version=6.18.45-1
kernel_release=6.18.45-1-rpi-16k
board_package=uconsole-cm5-dkms
board_version=0.1.r0.gbf7a0ab-1
board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a
STATE
awk -F '|' '$0 !~ /^#/ { print $1 "=" $2 }' "$REPO_ROOT/config/base-system/packages.lock" > "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages"
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" <<'STATE'
admin_user=fixture
hostname=uconsole-fixture
timezone=UTC
locale=en_US.UTF-8
keymap=us
reg_domain=US
ssh_key_fingerprint=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
wifi_preseed=no
network_manager=NetworkManager
STATE
printf 'root:x:0:0:root:/root:/usr/bin/bash\nalarm:x:1000:1000:Alarm:/home/alarm:/bin/bash\nfixture:x:1001:1001:Fixture:/home/fixture:/bin/bash\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\nwheel:x:998:alarm,fixture\nalarm:x:1000:\nfixture:x:1001:\n' > "$ROOT/etc/group"
printf 'root:!fixture-root:20000:0:99999:7:::\nalarm:!fixture-alarm:20000:0:99999:7:::\nfixture:$6$fixture$fixturehash:20000:0:99999:7:::\n' > "$ROOT/etc/shadow"
chmod 0600 "$ROOT/etc/shadow"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyKey fixture\n' > "$ROOT/home/fixture/.ssh/authorized_keys"
chmod 0600 "$ROOT/home/fixture/.ssh/authorized_keys"
sed 's/@ADMIN_USER@/fixture/g' "$REPO_ROOT/config/base-system/sshd_config.template" > "$ROOT/etc/ssh/sshd_config.d/10-uconsole.conf"
printf 'uconsole-fixture\n' > "$ROOT/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$ROOT/etc/locale.conf"
printf 'KEYMAP=us\n' > "$ROOT/etc/vconsole.conf"
printf 'fixture timezone\n' > "$ROOT/usr/share/zoneinfo/UTC"
ln -s /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
printf 'options cfg80211 ieee80211_regdom=US\n' > "$ROOT/etc/modprobe.d/90-uconsole-regdom.conf"
cp "$REPO_ROOT/config/base-system/NetworkManager.conf" "$ROOT/etc/NetworkManager/conf.d/10-uconsole.conf"

cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" <<'STATE'
hyprland_version=0.56.1-3
package_lock_sha256=1d469713047d2226bf934586f23073812c698c538a7085e8e4782dee38eba09e
transaction_lock_sha256=2bd6232e8e90da7f10e9245fb306f5d7578840e9452d42726607cf52483c1bc7
transaction_packages=204
config_sha256=f944368040661e3d88746e6c521c978a85e5b5beaeb62cf30ef460548adf0b60
target_user=fixture
session_start=start-hyprland
uwsm_enabled=no
STATE
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" <<'STATE'
userland_version=4.0.0.alpha-3
userland_sha256=4824a5b829cf6633e0d329307341398353fe14881c9642730e96bb7c31d93b71
upstream_commit=d99d4fc6de0bc99d48c9935724fa19d7fb41ae54
direct_lock_sha256=019a79e470a26a7b3c34adb5209f02269eca3cb4df78e70a15aa41619f097159
transaction_lock_sha256=9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3
transaction_packages=24
runtime_policy_sha256=5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d
runtime_commands=51
target_user=fixture
home_seeded=no
session_activated=no
uwsm_enabled=no
hardware_owned=no
updates_owned=no
STATE
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-fixture" <<'STATE'
target_user=fixture
upstream_commit=d99d4fc6de0bc99d48c9935724fa19d7fb41ae54
shell_sha256=b8f1995c5fbfe55252463c47f21cce833154f905a92d493a03981a21eac8ac9a
foot_sha256=a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf
migration_count=87
migration_lock_sha256=bf1cd979738bc9035731e881fae95072d64caf2bacb3705f9a47433a0aa7b143
historical_migrations_run=no
initial_theme=tokyo-night
session_modified=no
activation=no
STATE
mkdir -p "$ROOT/home/fixture/.config/hypr" "$ROOT/home/fixture/.config/omarchy" "$ROOT/home/fixture/.config/foot" "$ROOT/home/fixture/.local/state/omarchy/current"
cp "$REPO_ROOT/config/hyprland/minimal.lua" "$ROOT/home/fixture/.config/hypr/hyprland.lua"
cp "$REPO_ROOT/config/arm64-overrides/shell.json" "$ROOT/home/fixture/.config/omarchy/shell.json"
cp "$REPO_ROOT/config/arm64-overrides/foot.ini" "$ROOT/home/fixture/.config/foot/foot.ini"
ln -s /usr/share/omarchy-arm64/themes/tokyo-night "$ROOT/home/fixture/.local/state/omarchy/current/theme"
ln -s /usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp "$ROOT/home/fixture/.local/state/omarchy/current/background"
printf 'tokyo-night\n' > "$ROOT/home/fixture/.local/state/omarchy/current/theme.name"

COMMON_ARGS=(
  --root-tree "$ROOT"
  --disk-id c0decafe
  --boot-id A1B2C3D4
  --root-uuid 11111111-2222-4333-8444-555555555555
  --source-date-epoch 1787590000
  --size-mib 2048
  --boot-mib 256
)

PLAN_OUTPUT=''
if ! PLAN_OUTPUT=$("$BUILDER" "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/fixture.img" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected image plan fixture to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'PARTUUID=c0decafe-01 FAT-ID=A1B2C3D4' || {
  printf 'Plan did not report the expected boot identity\n' >&2
  exit 1
}
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'loop devices and physical devices were unchanged' || {
  printf 'Plan did not report its read-only boundary\n' >&2
  exit 1
}
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq '[PASS] Omarchy image state   not-required' || {
  printf 'Base plan did not preserve the optional Omarchy boundary\n' >&2
  exit 1
}
[[ ! -e "$OUTPUT_DIR/fixture.img" && ! -e "$OUTPUT_DIR/fixture.img.manifest.json" ]] || {
  printf 'Plan mode created output artifacts\n' >&2
  exit 1
}

OMARCHY_PLAN_OUTPUT=''
if ! OMARCHY_PLAN_OUTPUT=$("$BUILDER" "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/omarchy.img" --require-omarchy-prepared --plan); then
  printf '%s\n' "$OMARCHY_PLAN_OUTPUT" >&2
  printf 'Expected prepared-but-inactive Omarchy image plan to pass\n' >&2
  exit 1
fi
printf '%s\n' "$OMARCHY_PLAN_OUTPUT" | grep -Fq '[PASS] Omarchy image state   prepared-inactive' || {
  printf 'Omarchy image plan did not report the inactive desktop gate\n' >&2
  exit 1
}
[[ ! -e "$OUTPUT_DIR/omarchy.img" && ! -e "$OUTPUT_DIR/omarchy.img.manifest.json" ]] || {
  printf 'Omarchy plan mode created output artifacts\n' >&2
  exit 1
}

expect_rejected() {
  local label=$1
  shift
  local status=0
  "$BUILDER" "$@" >/dev/null 2>&1
  status=$?
  [[ $status -eq 2 ]] || {
    printf 'Expected %s to be rejected with status 2; got %s\n' "$label" "$status" >&2
    exit 1
  }
}

touch "$OUTPUT_DIR/existing.img"
expect_rejected 'existing output' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/existing.img" --plan
expect_rejected 'physical device option' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/device.img" --device /dev/mmcblk0
expect_rejected 'direct /dev output' "${COMMON_ARGS[@]}" --output /dev/mmcblk0 --plan
expect_rejected 'invalid UUID' \
  --root-tree "$ROOT" --output "$OUTPUT_DIR/bad-uuid.img" --disk-id c0decafe --boot-id A1B2C3D4 \
  --root-uuid not-a-uuid --source-date-epoch 1787590000 --plan

mkdir "$ROOT/image-output"
expect_rejected 'output below source root' "${COMMON_ARGS[@]}" --output "$ROOT/image-output/recursive.img" --plan

mv "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" "$TEST_TMP/hardware-selection"
expect_rejected 'missing hardware selection gate' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/no-gate.img" --plan
mv "$TEST_TMP/hardware-selection" "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection"

mv "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" "$TEST_TMP/base-system-selection"
expect_rejected 'missing base-system selection gate' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/no-base-gate.img" --plan
mv "$TEST_TMP/base-system-selection" "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection"

sed 's/^activation=no$/activation=yes/' "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-fixture" > "$TEST_TMP/user-preparation-fixture"
mv "$TEST_TMP/user-preparation-fixture" "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-fixture"
expect_rejected 'activated Omarchy preparation' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/activated-omarchy.img" --require-omarchy-prepared --plan
sed 's/^activation=yes$/activation=no/' "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-fixture" > "$TEST_TMP/user-preparation-fixture"
mv "$TEST_TMP/user-preparation-fixture" "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-fixture"

cp "$ROOT/etc/shadow" "$TEST_TMP/shadow"
sed 's/^root:![^:]*/root:unlocked/' "$TEST_TMP/shadow" > "$ROOT/etc/shadow"
expect_rejected 'unlocked root account' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/unlocked-root.img" --plan
mv "$TEST_TMP/shadow" "$ROOT/etc/shadow"

ln -s kernel8.img "$ROOT/boot/unsafe-link"
expect_rejected 'FAT symlink' "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/symlink.img" --plan
rm "$ROOT/boot/unsafe-link"

# --allow-default-credentials: the first-boot console workflow. The relaxed
# path must still refuse a root that cannot be logged into, must refuse a
# desktop payload, and must announce itself rather than pass silently.
mv "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" "$TEST_TMP/base-system-selection"

expect_rejected 'unconfigured root without the explicit flag' \
  "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/unconfigured-no-flag.img" --plan

UNCONFIGURED_OUTPUT=''
UNCONFIGURED_STDERR="$TEST_TMP/unconfigured.err"
if ! UNCONFIGURED_OUTPUT=$("$BUILDER" "${COMMON_ARGS[@]}" \
  --output "$OUTPUT_DIR/unconfigured.img" --allow-default-credentials --plan 2>"$UNCONFIGURED_STDERR"); then
  printf 'Expected unconfigured plan to pass with --allow-default-credentials\n' >&2
  sed -n '1,$p' "$UNCONFIGURED_STDERR" >&2
  exit 1
fi
printf '%s\n' "$UNCONFIGURED_OUTPUT" | grep -Fq 'first-boot policy    unconfigured; default credentials' || {
  printf 'Unconfigured plan did not report the relaxed first-boot policy\n' >&2
  exit 1
}
printf '%s\n' "$UNCONFIGURED_OUTPUT" | grep -Fq 'console login: fixture' || {
  printf 'Unconfigured plan did not name the login-capable account\n' >&2
  exit 1
}
grep -Fq 'WARNING: building an UNCONFIGURED image with default credentials.' "$UNCONFIGURED_STDERR" || {
  printf 'Unconfigured plan did not warn on stderr\n' >&2
  exit 1
}

expect_rejected 'prepared desktop payload on an unconfigured root' \
  "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/unconfigured-omarchy.img" \
  --allow-default-credentials --require-omarchy-prepared --plan

# Every account locked: the image would be unreachable without serial access,
# so the relaxed path must refuse rather than produce a brick.
cp "$ROOT/etc/shadow" "$TEST_TMP/shadow"
sed 's/^fixture:\$6\$[^:]*/fixture:!locked/' "$TEST_TMP/shadow" > "$ROOT/etc/shadow"
expect_rejected 'unconfigured root with no login-capable account' \
  "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/unconfigured-locked.img" --allow-default-credentials --plan
mv "$TEST_TMP/shadow" "$ROOT/etc/shadow"

mv "$TEST_TMP/base-system-selection" "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection"

expect_rejected 'already-configured root with --allow-default-credentials' \
  "${COMMON_ARGS[@]}" --output "$OUTPUT_DIR/configured-relaxed.img" --allow-default-credentials --plan

printf 'build-image plan and safety tests: PASS\n'
