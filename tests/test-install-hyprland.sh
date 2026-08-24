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
mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local" "$ROOT/var/lib/uconsole-omarchy-arm64" "$ROOT/home/alarm"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
printf 'alarm:x:%s:%s:Fixture User:/home/alarm:/bin/bash\n' "$CURRENT_UID" "$CURRENT_GID" > "$ROOT/etc/passwd"
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection" <<'STATE'
kernel_package=linux-rpi-16k
kernel_version=6.18.45-1
kernel_release=6.18.45-1-rpi-16k
board_package=uconsole-cm5-dkms
board_version=0.1.r0.gbf7a0ab-1
board_source_commit=bf7a0ab55654c96b74d013520e1196d39f66391a
STATE

ARGS=(
  --root "$ROOT"
  --user alarm
  --chroot-command "$FAKE_CHROOT"
  --lock-file "$LOCK"
  --config-template "$TEMPLATE"
)
LOG="$TEST_TMP/chroot.log"
: > "$LOG"

PLAN_OUTPUT=""
if ! PLAN_OUTPUT=$(FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" "$INSTALLER" "${ARGS[@]}" --plan); then
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

if ! FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected Hyprland apply fixture to pass\n' >&2
  exit 1
fi
cmp -s "$TEMPLATE" "$ROOT/home/alarm/.config/hypr/hyprland.lua" || { printf 'Installed Hyprland config differs\n' >&2; exit 1; }
[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || { printf 'Hyprland state missing\n' >&2; exit 1; }
grep -Fq 'uwsm_enabled=no' "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" || { printf 'UWSM policy missing\n' >&2; exit 1; }
grep -Fq 'pacman -S --needed --noconfirm hyprland' "$LOG" || { printf 'Package transaction not observed\n' >&2; exit 1; }

INSTALL_COUNT=$(grep -Fc 'pacman -S --needed --noconfirm' "$LOG")
if ! FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" "$INSTALLER" "${ARGS[@]}" --apply >/dev/null; then
  printf 'Expected idempotent Hyprland re-run to pass\n' >&2
  exit 1
fi
[[ $(grep -Fc 'pacman -S --needed --noconfirm' "$LOG") -eq $INSTALL_COUNT ]] || {
  printf 'Idempotent re-run repeated the package transaction\n' >&2
  exit 1
}

printf 'user edit\n' >> "$ROOT/home/alarm/.config/hypr/hyprland.lua"
CONFLICT_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" "$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
CONFLICT_STATUS=$?
[[ $CONFLICT_STATUS -eq 2 ]] || { printf 'Expected user config conflict to be rejected\n' >&2; exit 1; }

NO_GATE="$TEST_TMP/no-gate"
cp -R "$ROOT" "$NO_GATE"
rm "$NO_GATE/var/lib/uconsole-omarchy-arm64/hardware-selection"
NO_GATE_STATUS=0
FAKE_CHROOT_LOG="$LOG" FAKE_HYPRLAND_LOCK="$LOCK" "$INSTALLER" "${ARGS[@]/$ROOT/$NO_GATE}" --plan >/dev/null 2>&1
NO_GATE_STATUS=$?
[[ $NO_GATE_STATUS -eq 2 ]] || { printf 'Expected missing hardware gate to be rejected\n' >&2; exit 1; }

printf 'install-hyprland fixture tests: PASS\n'
