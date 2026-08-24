#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=''
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve test directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi
INSTALLER="$REPO_ROOT/scripts/install-base-system-packages.sh"
FAKE_CHROOT="$TEST_DIR/helpers/fake-arch-chroot.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-base-packages-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-base-packages-test.*|/private/tmp/uconsole-base-packages-test.*|/var/folders/*/T/uconsole-base-packages-test.*|/private/var/folders/*/T/uconsole-base-packages-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
create_package() {
  local name=$1 version=$2 architecture=$3 output=$4
  local staging="$TEST_TMP/pkg-$name"
  mkdir -p "$staging"
  printf 'pkgname = %s\npkgver = %s\narch = %s\n' "$name" "$version" "$architecture" > "$staging/.PKGINFO"
  bsdtar -cf "$output" -C "$staging" .PKGINFO
}

ROOT="$TEST_TMP/root"
PACKAGES="$TEST_TMP/packages"
mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local" "$ROOT/var/lib/uconsole-omarchy-arm64" "$PACKAGES"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" <<'STATE'
kernel_package=linux-rpi-16k
kernel_version=6.18.45-1
kernel_release=6.18.45-1-rpi-16k
board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a
STATE
: > "$ROOT/var/lib/fake-packages"

LOCK="$TEST_TMP/packages.lock"
: > "$LOCK"
for spec in 'networkmanager|1|aarch64' 'sudo|2|aarch64' 'bluez|3|aarch64' 'bluez-utils|3|aarch64' 'fixture-dependency|4|any'; do
  IFS='|' read -r name version architecture <<< "$spec"
  filename="$name-$version-$architecture.pkg.tar.xz"
  package="$PACKAGES/$filename"
  create_package "$name" "$version" "$architecture" "$package"
  printf '%s|%s|%s|%s|%s\n' "$name" "$version" "$architecture" "$(sha256_file "$package")" "$filename" >> "$LOCK"
done

ARGS=(--root "$ROOT" --package-dir "$PACKAGES" --lock-file "$LOCK" --chroot-command "$FAKE_CHROOT")
LOG="$TEST_TMP/chroot.log"
: > "$LOG"
PLAN_OUTPUT=$(FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --plan) || { printf 'Expected base package plan to pass\n' >&2; exit 1; }
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'No package cache, database, service or policy file was changed.' || { printf 'Plan boundary missing\n' >&2; exit 1; }
[[ ! -e "$ROOT/var/cache/pacman/pkg" ]] || { printf 'Plan created package cache\n' >&2; exit 1; }

FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected base package apply to pass\n' >&2; exit 1; }
for state in 'networkmanager=1' 'sudo=2' 'bluez=3' 'bluez-utils=3' 'fixture-dependency=4'; do
  grep -Fqx "$state" "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-packages" || { printf 'State missing: %s\n' "$state" >&2; exit 1; }
done
INSTALL_COUNT=$(grep -Fc 'pacman -U --needed --noconfirm' "$LOG")
FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected idempotent base package re-run to pass\n' >&2; exit 1; }
[[ $(grep -Fc 'pacman -U --needed --noconfirm' "$LOG") -eq $INSTALL_COUNT ]] || { printf 'Idempotent re-run repeated package transaction\n' >&2; exit 1; }

printf 'tamper\n' >> "$PACKAGES/bluez-3-aarch64.pkg.tar.xz"
TAMPER_STATUS=0
FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
TAMPER_STATUS=$?
[[ $TAMPER_STATUS -eq 2 ]] || { printf 'Expected tampered base package rejection\n' >&2; exit 1; }
printf 'install-base-system-packages fixture tests: PASS\n'
