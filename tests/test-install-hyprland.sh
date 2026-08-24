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
INSTALLER="$REPO_ROOT/scripts/install-hyprland.sh"
FAKE_CHROOT="$TEST_DIR/helpers/fake-hyprland-chroot.sh"
LOCK="$REPO_ROOT/config/hyprland/packages.lock"
TEMPLATE="$REPO_ROOT/config/hyprland/minimal.lua"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-hyprland-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-hyprland-test.*|/private/tmp/uconsole-hyprland-test.*|/var/folders/*/T/uconsole-hyprland-test.*|/private/var/folders/*/T/uconsole-hyprland-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

ROOT="$TEST_TMP/root"
PACKAGES="$TEST_TMP/packages"
TRANSACTION_LOCK="$TEST_TMP/transaction.lock"
mkdir "$PACKAGES"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}
file_size() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then stat -f '%z' "$1"
  else stat -c '%s' "$1"
  fi
}
create_package() {
  local name=$1
  local version=$2
  local architecture=$3
  local destination=$4
  local package_root="$TEST_TMP/package-root"
  rm -rf -- "$package_root"
  mkdir "$package_root"
  printf 'pkgname = %s\npkgver = %s\narch = %s\n' "$name" "$version" "$architecture" > "$package_root/.PKGINFO"
  bsdtar -cf "$destination" -C "$package_root" .PKGINFO
}
printf '# name|version|architecture|repository|kind|sha256|signature_sha256|filename|size\n' > "$TRANSACTION_LOCK"
while IFS='|' read -r package_name package_version package_architecture package_repository package_role; do
  [[ -n "$package_name" && "$package_name" != \#* ]] || continue
  filename="$package_name-$package_version-$package_architecture.pkg.tar.xz"
  package="$PACKAGES/$filename"
  create_package "$package_name" "$package_version" "$package_architecture" "$package"
  printf 'fixture signature for %s\n' "$package_name" > "${package}.sig"
  printf '%s|%s|%s|%s|direct|%s|%s|%s|%s\n' \
    "$package_name" "$package_version" "$package_architecture" "$package_repository" \
    "$(sha256_file "$package")" "$(sha256_file "${package}.sig")" "$filename" "$(file_size "$package")" >> "$TRANSACTION_LOCK"
done < "$LOCK"

mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local" "$ROOT/var/lib/uconsole-omarchy-arm64" "$ROOT/home/alarm" "$ROOT/home/other"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
# The fixture stamps the runner's own UID/GID into the target passwd database so
# that ownership assertions work without privileges. The installer legitimately
# refuses a UID-0 graphical session owner, so a root runner would otherwise fail
# deep inside the installer with a misleading message.
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
[[ "$CURRENT_UID" -gt 0 ]] || {
  printf 'This test must run as a non-root user; the fixture graphical owner cannot be UID 0.\n' >&2
  exit 1
}
printf 'alarm:x:%s:%s:Fixture User:/home/alarm:/bin/bash\nother:x:%s:%s:Other User:/home/other:/bin/bash\n' "$CURRENT_UID" "$CURRENT_GID" "$CURRENT_UID" "$CURRENT_GID" > "$ROOT/etc/passwd"
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
admin_user=alarm
hostname=uconsole-fixture
timezone=UTC
locale=en_US.UTF-8
keymap=us
reg_domain=US
ssh_key_fingerprint=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
wifi_preseed=no
network_manager=NetworkManager
STATE

ARGS=(
  --root "$ROOT"
  --user alarm
  --chroot-command "$FAKE_CHROOT"
  --lock-file "$LOCK"
  --transaction-lock "$TRANSACTION_LOCK"
  --package-dir "$PACKAGES"
  --config-template "$TEMPLATE"
)
LOG="$TEST_TMP/chroot.log"
: > "$LOG"

PLAN_OUTPUT=""
if ! PLAN_OUTPUT=$(FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]}" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected Hyprland plan fixture to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'No package, user configuration, service or boot file was changed.' || {
  printf 'Plan did not report its read-only result\n' >&2
  exit 1
}
[[ ! -e "$ROOT/home/alarm/.config" ]] || { printf 'Plan wrote user configuration\n' >&2; exit 1; }
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || { printf 'Plan wrote selection state\n' >&2; exit 1; }

FIRST_SIGNATURE="$PACKAGES/$(awk -F '|' '$0 !~ /^#/ { print $8 ".sig"; exit }' "$TRANSACTION_LOCK")"
cp "$FIRST_SIGNATURE" "$TEST_TMP/first-signature"
printf 'tamper\n' >> "$FIRST_SIGNATURE"
TAMPER_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
TAMPER_STATUS=$?
[[ $TAMPER_STATUS -eq 2 ]] || { printf 'Expected tampered transaction signature rejection\n' >&2; exit 1; }
mv "$TEST_TMP/first-signature" "$FIRST_SIGNATURE"

if ! FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected Hyprland apply fixture to pass\n' >&2
  exit 1
fi
cmp -s "$TEMPLATE" "$ROOT/home/alarm/.config/hypr/hyprland.lua" || { printf 'Installed Hyprland config differs\n' >&2; exit 1; }
[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || { printf 'Hyprland state missing\n' >&2; exit 1; }
grep -Fq 'uwsm_enabled=no' "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" || { printf 'UWSM policy missing\n' >&2; exit 1; }
grep -Fq 'pacman -U --needed --noconfirm /var/cache/pacman/pkg/' "$LOG" || { printf 'Package transaction not observed\n' >&2; exit 1; }

INSTALL_COUNT=$(grep -Fc 'pacman -U --needed --noconfirm' "$LOG")
if ! FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected idempotent Hyprland re-run to pass\n' >&2
  exit 1
fi
[[ $(grep -Fc 'pacman -U --needed --noconfirm' "$LOG") -eq $INSTALL_COUNT ]] || {
  printf 'Idempotent re-run repeated the package transaction\n' >&2
  exit 1
}

printf 'user edit\n' >> "$ROOT/home/alarm/.config/hypr/hyprland.lua"
CONFLICT_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
CONFLICT_STATUS=$?
[[ $CONFLICT_STATUS -eq 2 ]] || { printf 'Expected user config conflict to be rejected\n' >&2; exit 1; }

NO_GATE="$TEST_TMP/no-gate"
cp -R "$ROOT" "$NO_GATE"
rm "$NO_GATE/var/lib/uconsole-omarchy-arm64/hardware-selection"
NO_GATE_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]/$ROOT/$NO_GATE}" --plan >/dev/null 2>&1
NO_GATE_STATUS=$?
[[ $NO_GATE_STATUS -eq 2 ]] || { printf 'Expected missing hardware gate to be rejected\n' >&2; exit 1; }

NO_BASE_GATE="$TEST_TMP/no-base-gate"
cp -R "$ROOT" "$NO_BASE_GATE"
rm "$NO_BASE_GATE/var/lib/uconsole-omarchy-arm64/base-system-selection"
NO_BASE_GATE_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${ARGS[@]/$ROOT/$NO_BASE_GATE}" --plan >/dev/null 2>&1
NO_BASE_GATE_STATUS=$?
[[ $NO_BASE_GATE_STATUS -eq 2 ]] || { printf 'Expected missing base-system gate to be rejected\n' >&2; exit 1; }

OTHER_ARGS=("${ARGS[@]}")
for arg_index in "${!OTHER_ARGS[@]}"; do
  if [[ "${OTHER_ARGS[$arg_index]}" == alarm ]]; then OTHER_ARGS[$arg_index]=other; fi
done
OTHER_USER_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" FAKE_HYPRLAND_TRANSACTION_LOCK="$TRANSACTION_LOCK" "$INSTALLER" "${OTHER_ARGS[@]}" --plan >/dev/null 2>&1
OTHER_USER_STATUS=$?
[[ $OTHER_USER_STATUS -eq 2 ]] || { printf 'Expected non-selected graphical user to be rejected\n' >&2; exit 1; }

printf 'install-hyprland fixture tests: PASS\n'
