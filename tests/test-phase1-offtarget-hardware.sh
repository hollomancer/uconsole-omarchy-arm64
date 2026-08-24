#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/validate-phase1-offtarget-hardware.sh"
INSIDE="$REPO_ROOT/research/container/validate-phase1-offtarget-hardware-inside.sh"

bash -n "$RUNNER" "$INSIDE"

HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'retained volume is mounted'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'read-only'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'no image, block device, network or hardware is used'

for forbidden in --apply --configure --build --build-image --device --write-device --publish; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || {
    printf 'Expected runner %s to be rejected\n' "$forbidden" >&2
    exit 1
  }
done

grep -Fq -- '--read-only --log-driver none' "$RUNNER"
grep -Fq -- '--platform linux/arm64 --network none' "$RUNNER"
grep -Fq 'dst=/repo,readonly' "$RUNNER"
grep -Fq 'dst=/source,readonly' "$RUNNER"
grep -Fq -- '--tmpfs /source/root/tmp:exec' "$RUNNER"
grep -Fq -- '--tmpfs /source/root/dev:exec' "$RUNNER"
! grep -Fq -- '--privileged' "$RUNNER"

grep -Fq 'fdtoverlay' "$INSIDE"
grep -Fq 'bcm2712-rpi-cm5-cm5io.dtb' "$INSIDE"
grep -Fq 'uconsole-cm5-base.dtbo' "$INSIDE"
grep -Fq 'uconsole-audio-cm5.dtbo' "$INSIDE"
grep -Fq 'depmod -e -F' "$INSIDE"
grep -Fq 'modprobe -d "$ROOT" -S "$RELEASE" -n -v' "$INSIDE"
grep -Fq 'lsinitcpio -l /boot/initramfs-linux.img' "$INSIDE"
grep -Fq 'brcmfmac43455-sdio.raspberrypi,5-compute-module.txt' "$INSIDE"
grep -Fq 'BCM4345C0.hcd' "$INSIDE"
grep -Fq 'no hardware probe or accelerated render claimed' "$INSIDE"
! grep -Eq '(^|[[:space:]])mount[[:space:]]' "$INSIDE"
! grep -Eq '(^|[[:space:]])(pacman|mkinitcpio|dkms)[[:space:]].*(-S|-U|install|remove)' "$INSIDE"
! grep -Fq '|| true' "$INSIDE"

printf 'Phase 1 off-target hardware validator contract tests: PASS\n'
