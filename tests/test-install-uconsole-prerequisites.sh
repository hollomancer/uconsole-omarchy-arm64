#!/usr/bin/env bash

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
INSTALLER="$REPO_ROOT/scripts/install-uconsole-prerequisites.sh"
FAKE_CHROOT="$TEST_DIR/helpers/fake-arch-chroot.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-prerequisites-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-prerequisites-test.*|/private/tmp/uconsole-prerequisites-test.*|/var/folders/*/T/uconsole-prerequisites-test.*|/private/var/folders/*/T/uconsole-prerequisites-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

create_package() {
  local name=$1
  local version=$2
  local architecture=$3
  local output=$4
  local staging="$TEST_TMP/pkg-$name"
  mkdir -p "$staging"
  {
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = %s\n' "$version"
    printf 'arch = %s\n' "$architecture"
  } > "$staging/.PKGINFO"
  bsdtar -cf "$output" -C "$staging" .PKGINFO
}

ROOT="$TEST_TMP/root"
PACKAGES="$TEST_TMP/packages"
mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local" "$PACKAGES"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
: > "$ROOT/var/lib/fake-packages"

ALPHA="$PACKAGES/alpha-1-aarch64.pkg.tar.xz"
BETA="$PACKAGES/beta-2-any.pkg.tar.xz"
create_package alpha 1 aarch64 "$ALPHA"
create_package beta 2 any "$BETA"
LOCK="$TEST_TMP/prerequisites.lock"
{
  printf 'alpha|1|aarch64|%s|%s\n' "$(sha256_file "$ALPHA")" "${ALPHA##*/}"
  printf 'beta|2|any|%s|%s\n' "$(sha256_file "$BETA")" "${BETA##*/}"
} > "$LOCK"

ARGS=(
  --root "$ROOT"
  --package-dir "$PACKAGES"
  --lock-file "$LOCK"
  --chroot-command "$FAKE_CHROOT"
)
LOG="$TEST_TMP/chroot.log"
: > "$LOG"

PLAN_OUTPUT=''
if ! PLAN_OUTPUT=$(FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected prerequisite plan fixture to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'No package cache, database, root file or boot file was changed.' || {
  printf 'Plan did not report its read-only boundary\n' >&2
  exit 1
}
[[ ! -e "$ROOT/var/cache/pacman/pkg" ]] || { printf 'Plan created a package cache\n' >&2; exit 1; }

FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null || {
  printf 'Expected prerequisite apply fixture to pass\n' >&2
  exit 1
}
grep -Fqx 'alpha=1' "$ROOT/var/lib/uconsole-omarchy-arm64/build-prerequisites-selection" || { printf 'Alpha state missing\n' >&2; exit 1; }
grep -Fqx 'beta=2' "$ROOT/var/lib/uconsole-omarchy-arm64/build-prerequisites-selection" || { printf 'Beta state missing\n' >&2; exit 1; }
INSTALL_COUNT=$(grep -Fc 'pacman -U --needed --noconfirm' "$LOG")

FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null || {
  printf 'Expected idempotent prerequisite re-run to pass\n' >&2
  exit 1
}
[[ $(grep -Fc 'pacman -U --needed --noconfirm' "$LOG") -eq $INSTALL_COUNT ]] || {
  printf 'Idempotent re-run repeated prerequisite transaction\n' >&2
  exit 1
}

printf 'tamper\n' >> "$BETA"
TAMPER_STATUS=0
FAKE_CHROOT_LOG="$LOG" "$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
TAMPER_STATUS=$?
[[ $TAMPER_STATUS -eq 2 ]] || { printf 'Expected tampered package rejection\n' >&2; exit 1; }

printf 'install-uconsole-prerequisites fixture tests: PASS\n'
