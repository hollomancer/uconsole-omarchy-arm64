#!/usr/bin/env bash

# Verify and extract the real pinned Arch Linux ARM rootfs into a Linux volume.

set -u
set -o pipefail
umask 022

ROOTFS=/input/ArchLinuxARM-rootfs.tar.gz
SIGNATURE=/input/ArchLinuxARM-rootfs.tar.gz.sig
KEYRING_PACKAGE=/input/archlinuxarm-keyring.pkg.tar.xz
ARMORED_KEYRING=/work/archlinuxarm.asc
TRUSTED_KEYRING=/work/archlinuxarm.gpg
DESTINATION=/output/root
EXPECTED_ROOTFS_SHA=f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967
EXPECTED_SIGNER=68B3537F39A313B3E574D06777193F152BDBE6A6

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'Linux output volume must be empty'
mkdir -p /work || fail 'unable to create private work directory'
if ! bsdtar -xOf "$KEYRING_PACKAGE" usr/share/pacman/keyrings/archlinuxarm.gpg > "$ARMORED_KEYRING"; then
  fail 'unable to extract the pinned trusted keyring'
fi
gpg --batch --yes --dearmor --output "$TRUSTED_KEYRING" "$ARMORED_KEYRING" || fail 'unable to dearmor the pinned trusted keyring'
[[ -s "$TRUSTED_KEYRING" ]] || fail 'trusted keyring is empty'

/repo/scripts/bootstrap-arch.sh \
  --extract-root \
  --rootfs "$ROOTFS" \
  --rootfs-sha256 "$EXPECTED_ROOTFS_SHA" \
  --signature "$SIGNATURE" \
  --keyring "$TRUSTED_KEYRING" \
  --signer-fingerprint "$EXPECTED_SIGNER" \
  --root-tree "$DESTINATION" || fail 'signed rootfs extraction failed'

[[ $(stat -c '%u:%g' "$DESTINATION") == 0:0 ]] || fail 'root directory numeric ownership differs'
[[ $(stat -c '%u:%g' "$DESTINATION/home/alarm") == 1000:1000 ]] || fail 'alarm home numeric ownership differs'
[[ -L "$DESTINATION/bin" && $(readlink "$DESTINATION/bin") == usr/bin ]] || fail '/bin symlink was not preserved'
grep -Fqx "rootfs_sha256=$EXPECTED_ROOTFS_SHA" "$DESTINATION/var/lib/uconsole-omarchy-arm64/rootfs-selection" || fail 'root selection digest differs'
grep -Fqx "signature_fingerprint=$EXPECTED_SIGNER" "$DESTINATION/var/lib/uconsole-omarchy-arm64/rootfs-selection" || fail 'root selection signer differs'
find "$DESTINATION/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d -name 'linux-aarch64-*' -print -quit | grep -q . || fail 'generic source kernel package state is missing'
grep -Fq '/dev/mmcblk0p1' "$DESTINATION/etc/fstab" || fail 'expected source fstab evidence is missing'
grep -Eq '^root:' "$DESTINATION/etc/passwd" || fail 'source root account evidence is missing'
grep -Eq '^alarm:' "$DESTINATION/etc/passwd" || fail 'source alarm account evidence is missing'

printf '[PASS] numeric ownership      root=0:0 alarm-home=1000:1000\n'
printf '[PASS] source identity        generic kernel, source fstab and default accounts observed\n'
printf '[PASS] extraction boundary    Linux volume retained at /output/root; no image or device written\n'
printf 'signed rootfs extraction integration test: PASS\n'
