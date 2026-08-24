#!/usr/bin/env bash

# Runs inside the pinned ARM64 integration-test container. It builds a regular
# fixture image, mounts only its loop partitions, and verifies image identity.

set -u
set -o pipefail
umask 022

REPO_ROOT=/repo
FIXTURE_ROOT=/work/root
OUTPUT=/output/fixture.img
DOSFSTOOLS=/input/dosfstools.pkg.tar.xz
MTOOLS=/input/mtools.pkg.tar.xz

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pacman -U --needed --noconfirm "$DOSFSTOOLS" "$MTOOLS" || fail 'unable to install pinned image tools'

mkdir -p \
  "$FIXTURE_ROOT/etc" \
  "$FIXTURE_ROOT/etc/NetworkManager/conf.d" \
  "$FIXTURE_ROOT/etc/NetworkManager/system-connections" \
  "$FIXTURE_ROOT/etc/modprobe.d" \
  "$FIXTURE_ROOT/etc/ssh/sshd_config.d" \
  "$FIXTURE_ROOT/boot/overlays" \
  "$FIXTURE_ROOT/home/fixture/.ssh" \
  "$FIXTURE_ROOT/usr/share/zoneinfo" \
  "$FIXTURE_ROOT/usr/share/uconsole-image-fixture" \
  "$FIXTURE_ROOT/var/lib/pacman/local" \
  "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64" || fail 'unable to create fixture tree'
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$FIXTURE_ROOT/etc/os-release" || fail 'unable to write OS identity'
printf '%s\n' '# source fixture; must remain unchanged' > "$FIXTURE_ROOT/etc/fstab" || fail 'unable to write source fstab'
printf '%s\n' 'root=/dev/mmcblk0p2 rw' > "$FIXTURE_ROOT/boot/cmdline.txt" || fail 'unable to write source cmdline'
cat > "$FIXTURE_ROOT/boot/config.txt" <<'CONFIG'
arm_64bit=1
initramfs initramfs-linux.img followkernel
dtoverlay=vc4-kms-v3d
[cm5]
dtoverlay=dwc2,dr_mode=host
[all]
# BEGIN uconsole-omarchy-arm64 hardware include
include uconsole-cm5.txt
# END uconsole-omarchy-arm64 hardware include
CONFIG
cat > "$FIXTURE_ROOT/boot/uconsole-cm5.txt" <<'CONFIG'
dtparam=ant2
dtoverlay=uconsole-cm5-base
dtoverlay=uconsole-audio-cm5
CONFIG

for boot_file in \
  kernel8.img \
  initramfs-linux.img \
  start4.elf \
  fixup4.dat \
  bcm2712-rpi-cm5-cm5io.dtb \
  overlays/vc4-kms-v3d.dtbo \
  overlays/uconsole-cm5-base.dtbo \
  overlays/uconsole-audio-cm5.dtbo; do
  printf 'integration fixture: %s\n' "$boot_file" > "$FIXTURE_ROOT/boot/$boot_file" || fail "unable to write $boot_file"
done
truncate -s 2M "$FIXTURE_ROOT/boot/kernel8.img" || fail 'unable to size fixture kernel'
truncate -s 3M "$FIXTURE_ROOT/boot/initramfs-linux.img" || fail 'unable to size fixture initramfs'
printf '%s\n' 'fixture root payload' > "$FIXTURE_ROOT/usr/share/uconsole-image-fixture/payload.txt" || fail 'unable to write fixture payload'
cat > "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" <<'STATE'
kernel_package=linux-rpi-16k
kernel_version=6.18.45-1
kernel_release=6.18.45-1-rpi-16k
board_package=uconsole-cm5-dkms
board_version=0.1.r0.gbf7a0ab-1
board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a
STATE
awk -F '|' '$0 !~ /^#/ { print $1 "=" $2 }' "$REPO_ROOT/config/base-system/packages.lock" > "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages" || fail 'unable to write base package state'
cat > "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" <<'STATE'
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
printf 'root:x:0:0:root:/root:/usr/bin/bash\nalarm:x:1000:1000:Alarm:/home/alarm:/bin/bash\nfixture:x:1001:1001:Fixture:/home/fixture:/bin/bash\n' > "$FIXTURE_ROOT/etc/passwd" || fail 'unable to write passwd fixture'
printf 'root:x:0:\nwheel:x:998:alarm,fixture\nalarm:x:1000:\nfixture:x:1001:\n' > "$FIXTURE_ROOT/etc/group" || fail 'unable to write group fixture'
printf 'root:!fixture-root:20000:0:99999:7:::\nalarm:!fixture-alarm:20000:0:99999:7:::\nfixture:$6$fixture$fixturehash:20000:0:99999:7:::\n' > "$FIXTURE_ROOT/etc/shadow" || fail 'unable to write shadow fixture'
chmod 0600 "$FIXTURE_ROOT/etc/shadow" || fail 'unable to secure shadow fixture'
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyKey fixture\n' > "$FIXTURE_ROOT/home/fixture/.ssh/authorized_keys" || fail 'unable to write SSH fixture'
chmod 0600 "$FIXTURE_ROOT/home/fixture/.ssh/authorized_keys" || fail 'unable to secure SSH fixture'
sed 's/@ADMIN_USER@/fixture/g' "$REPO_ROOT/config/base-system/sshd_config.template" > "$FIXTURE_ROOT/etc/ssh/sshd_config.d/10-uconsole.conf" || fail 'unable to write sshd fixture'
printf 'uconsole-fixture\n' > "$FIXTURE_ROOT/etc/hostname" || fail 'unable to write hostname fixture'
printf 'LANG=en_US.UTF-8\n' > "$FIXTURE_ROOT/etc/locale.conf" || fail 'unable to write locale fixture'
printf 'KEYMAP=us\n' > "$FIXTURE_ROOT/etc/vconsole.conf" || fail 'unable to write keymap fixture'
printf 'fixture timezone\n' > "$FIXTURE_ROOT/usr/share/zoneinfo/UTC" || fail 'unable to write timezone fixture'
ln -s /usr/share/zoneinfo/UTC "$FIXTURE_ROOT/etc/localtime" || fail 'unable to link timezone fixture'
printf 'options cfg80211 ieee80211_regdom=US\n' > "$FIXTURE_ROOT/etc/modprobe.d/90-uconsole-regdom.conf" || fail 'unable to write regulatory fixture'
cp "$REPO_ROOT/config/base-system/NetworkManager.conf" "$FIXTURE_ROOT/etc/NetworkManager/conf.d/10-uconsole.conf" || fail 'unable to write NetworkManager fixture'

"$REPO_ROOT/scripts/build-image.sh" \
  --build \
  --root-tree "$FIXTURE_ROOT" \
  --output "$OUTPUT" \
  --size-mib 2048 \
  --boot-mib 256 \
  --disk-id c0decafe \
  --boot-id A1B2C3D4 \
  --root-uuid 11111111-2222-4333-8444-555555555555 \
  --source-date-epoch 1787590000 || fail 'regular image build failed'

[[ -f "$OUTPUT" && ! -b "$OUTPUT" ]] || fail 'builder did not produce a regular file'
[[ $(stat -c '%s' "$OUTPUT") -eq 2147483648 ]] || fail 'image size is not exactly 2048 MiB'
[[ -f "${OUTPUT}.manifest.json" ]] || fail 'external manifest is missing'
grep -Fq '"image": "fixture.img"' "${OUTPUT}.manifest.json" || fail 'external manifest has wrong image name'
grep -Fq '"image_size": 2147483648' "${OUTPUT}.manifest.json" || fail 'external manifest has wrong image size'
grep -Fq '"disk_id": "c0decafe"' "${OUTPUT}.manifest.json" || fail 'external manifest has wrong disk ID'

SFDISK_JSON=$(sfdisk --json "$OUTPUT") || fail 'unable to inspect partition table'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"id": "0xc0decafe"' || fail 'MBR disk ID differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 8192' || fail 'boot start sector differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 524288' || fail 'boot size differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"start": 532480' || fail 'root start sector differs'
printf '%s\n' "$SFDISK_JSON" | grep -Fq '"size": 3659776' || fail 'root size differs'

BOOT_LOOP_DEVICE=''
ROOT_LOOP_DEVICE=''
MOUNT_ROOT=''
BOOT_MOUNTED=0
ROOT_MOUNTED=0
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $BOOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT/boot" || status=1; fi
  if [[ $ROOT_MOUNTED -eq 1 ]]; then umount "$MOUNT_ROOT" || status=1; fi
  if [[ -n "$ROOT_LOOP_DEVICE" ]]; then losetup -d "$ROOT_LOOP_DEVICE" || status=1; fi
  if [[ -n "$BOOT_LOOP_DEVICE" ]]; then losetup -d "$BOOT_LOOP_DEVICE" || status=1; fi
  if [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]]; then rmdir "$MOUNT_ROOT" || status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BOOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset 4194304 --sizelimit 268435456 "$OUTPUT") || fail 'unable to attach boot range read-only'
ROOT_LOOP_DEVICE=$(losetup --find --show --read-only --offset 272629760 --sizelimit 1873805312 "$OUTPUT") || fail 'unable to attach root range read-only'
BOOT_DEVICE=$BOOT_LOOP_DEVICE
ROOT_DEVICE=$ROOT_LOOP_DEVICE
[[ $(blkid -s UUID -o value "$BOOT_DEVICE") == A1B2-C3D4 ]] || fail 'FAT UUID differs'
[[ $(blkid -s UUID -o value "$ROOT_DEVICE") == 11111111-2222-4333-8444-555555555555 ]] || fail 'ext4 UUID differs'
[[ $(blkid -s TYPE -o value "$BOOT_DEVICE") == vfat ]] || fail 'boot filesystem type differs'
[[ $(blkid -s TYPE -o value "$ROOT_DEVICE") == ext4 ]] || fail 'root filesystem type differs'

MOUNT_ROOT=$(mktemp -d /work/inspect.XXXXXX) || fail 'unable to create inspection mount'
mount -o ro "$ROOT_DEVICE" "$MOUNT_ROOT" || fail 'unable to mount completed root read-only'
ROOT_MOUNTED=1
mount -o ro "$BOOT_DEVICE" "$MOUNT_ROOT/boot" || fail 'unable to mount completed boot read-only'
BOOT_MOUNTED=1

grep -Fqx 'PARTUUID=c0decafe-02  /      ext4  defaults,noatime  0 1' "$MOUNT_ROOT/etc/fstab" || fail 'rendered root fstab entry differs'
grep -Fqx 'PARTUUID=c0decafe-01  /boot  vfat  defaults,noatime  0 2' "$MOUNT_ROOT/etc/fstab" || fail 'rendered boot fstab entry differs'
grep -Fqx 'root=PARTUUID=c0decafe-02 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes' "$MOUNT_ROOT/boot/cmdline.txt" || fail 'rendered cmdline differs'
grep -Fqx 'root_uuid=11111111-2222-4333-8444-555555555555' "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/image-selection" || fail 'image selection state differs'
grep -Fq '"path": "kernel8.img"' "$MOUNT_ROOT/boot/uconsole-build-manifest.json" || fail 'boot manifest lacks kernel'
grep -Fq '"path": "overlays/uconsole-cm5-base.dtbo"' "$MOUNT_ROOT/boot/uconsole-build-manifest.json" || fail 'boot manifest lacks board overlay'
cmp -s "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" || fail 'hardware selection state was not preserved'
cmp -s "$FIXTURE_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" "$MOUNT_ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" || fail 'base-system selection state was not preserved'
grep -Fqx 'fixture root payload' "$MOUNT_ROOT/usr/share/uconsole-image-fixture/payload.txt" || fail 'root payload is missing'

grep -Fqx '# source fixture; must remain unchanged' "$FIXTURE_ROOT/etc/fstab" || fail 'builder mutated source fstab'
grep -Fqx 'root=/dev/mmcblk0p2 rw' "$FIXTURE_ROOT/boot/cmdline.txt" || fail 'builder mutated source cmdline'

printf 'image-builder ARM64 Linux integration test: PASS\n'
