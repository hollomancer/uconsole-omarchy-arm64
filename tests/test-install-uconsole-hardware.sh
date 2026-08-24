#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=""
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi
INSTALLER="$REPO_ROOT/scripts/install-uconsole-hardware.sh"
FAKE_CHROOT="$TEST_DIR/helpers/fake-arch-chroot.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-hardware-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-hardware-test.*|/private/tmp/uconsole-hardware-test.*|/var/folders/*/T/uconsole-hardware-test.*|/private/var/folders/*/T/uconsole-hardware-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

create_package() {
  local name=$1
  local version=$2
  local output=$3
  local staging="$TEST_TMP/pkg-$name"
  mkdir -p "$staging"
  {
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = %s\n' "$version"
    printf 'arch = aarch64\n'
  } > "$staging/.PKGINFO"
  bsdtar -cf "$output" -C "$staging" .PKGINFO
}

ROOT="$TEST_TMP/root"
mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
printf '%s\n' \
  '# stock fixture' \
  'dtoverlay=vc4-kms-v3d' \
  '[cm5]' \
  'dtoverlay=dwc2,dr_mode=host' \
  '[all]' > "$ROOT/boot/config.txt"
printf '%s\n' 'linux-aarch64 7.1.6-1' 'uboot-raspberrypi 2026.01-1' > "$ROOT/var/lib/fake-packages"

KERNEL="$TEST_TMP/linux-rpi-16k-fixture.pkg.tar.xz"
HEADERS="$TEST_TMP/linux-rpi-16k-headers-fixture.pkg.tar.xz"
BOARD="$TEST_TMP/uconsole-cm5-dkms-fixture.pkg.tar.xz"
create_package linux-rpi-16k fixture-1 "$KERNEL"
create_package linux-rpi-16k-headers fixture-1 "$HEADERS"
create_package uconsole-cm5-dkms 0.1.r0.gbf7a0ab-1 "$BOARD"

LOCK="$TEST_TMP/packages.lock"
{
  printf 'linux-rpi-16k|fixture-1|%s|fixture-rpi-16k\n' "$(sha256_file "$KERNEL")"
  printf 'linux-rpi-16k-headers|fixture-1|%s|fixture-rpi-16k\n' "$(sha256_file "$HEADERS")"
  printf 'uconsole-cm5-dkms|0.1.r0.gbf7a0ab-1|%s|bf7a0ab55654c96b74d013520e1196d39f66391a\n' "$(sha256_file "$BOARD")"
} > "$LOCK"

ARGS=(
  --root "$ROOT"
  --kernel linux-rpi-16k
  --kernel-package "$KERNEL"
  --headers-package "$HEADERS"
  --board-package "$BOARD"
  --lock-file "$LOCK"
  --chroot-command "$FAKE_CHROOT"
)

PLAN_OUTPUT=""
if ! PLAN_OUTPUT=$("$INSTALLER" "${ARGS[@]}" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected hardware plan to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'No package database, module tree, or boot file was changed.' || {
  printf 'Plan did not report its read-only result\n' >&2
  exit 1
}
[[ ! -e "$ROOT/boot/uconsole-cm5.txt" ]] || { printf 'Plan wrote the boot include\n' >&2; exit 1; }

LOG="$TEST_TMP/chroot.log"
: > "$LOG"
if ! FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected hardware apply fixture to pass\n' >&2
  exit 1
fi
[[ -s "$ROOT/boot/overlays/uconsole-cm5-base.dtbo" ]] || { printf 'Base overlay missing\n' >&2; exit 1; }
[[ -s "$ROOT/boot/overlays/uconsole-audio-cm5.dtbo" ]] || { printf 'Audio overlay missing\n' >&2; exit 1; }
[[ -f "$ROOT/boot/config.txt.pre-uconsole" ]] || { printf 'Boot backup missing\n' >&2; exit 1; }
[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" ]] || { printf 'Hardware state missing\n' >&2; exit 1; }
[[ $(grep -Fxc '# BEGIN uconsole-omarchy-arm64 hardware include' "$ROOT/boot/config.txt") -eq 1 ]] || {
  printf 'Managed include marker count is wrong\n' >&2
  exit 1
}
grep -Fq 'pacman -Rdd --noconfirm linux-aarch64 uboot-raspberrypi' "$LOG" || {
  printf 'Expected precise generic-package removal was not requested\n' >&2
  exit 1
}
grep -Fq 'pacman -U --noconfirm' "$LOG" || { printf 'Package transaction not observed\n' >&2; exit 1; }

INSTALL_COUNT=$(grep -Fc 'pacman -U --noconfirm' "$LOG")
if ! FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected idempotent hardware re-run to pass\n' >&2
  exit 1
fi
[[ $(grep -Fc 'pacman -U --noconfirm' "$LOG") -eq $INSTALL_COUNT ]] || {
  printf 'Idempotent re-run repeated the package transaction\n' >&2
  exit 1
}
[[ $(grep -Fxc '# BEGIN uconsole-omarchy-arm64 hardware include' "$ROOT/boot/config.txt") -eq 1 ]] || {
  printf 'Idempotent re-run duplicated the include block\n' >&2
  exit 1
}

CONFLICT_ROOT="$TEST_TMP/conflict-root"
cp -R "$ROOT" "$CONFLICT_ROOT"
printf 'dtparam=spi=on\n' >> "$CONFLICT_ROOT/boot/config.txt"
CONFLICT_STATUS=0
"$INSTALLER" "${ARGS[@]/$ROOT/$CONFLICT_ROOT}" --plan >/dev/null 2>&1
CONFLICT_STATUS=$?
[[ $CONFLICT_STATUS -eq 2 ]] || { printf 'Expected active SPI conflict to be rejected\n' >&2; exit 1; }

printf 'tamper\n' >> "$BOARD"
TAMPER_STATUS=0
"$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
TAMPER_STATUS=$?
[[ $TAMPER_STATUS -eq 2 ]] || { printf 'Expected tampered board package to be rejected\n' >&2; exit 1; }

printf 'install-uconsole-hardware fixture tests: PASS\n'

