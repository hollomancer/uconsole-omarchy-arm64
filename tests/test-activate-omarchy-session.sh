#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
ACTIVATOR="$REPO_ROOT/scripts/activate-omarchy-session.sh"
MINIMAL="$REPO_ROOT/config/hyprland/minimal.lua"
GUARD_SOURCE="$REPO_ROOT/config/omarchy-session/omarchy-session-arm64"

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
[[ "$CURRENT_UID" -gt 0 ]] || {
  printf 'This test must run as a non-root user; the fixture session owner cannot be UID 0.\n' >&2
  exit 1
}

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-session-handoff-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-session-handoff-test.*|/private/tmp/uconsole-session-handoff-test.*|/var/folders/*/T/uconsole-session-handoff-test.*|/private/var/folders/*/T/uconsole-session-handoff-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

MINIMAL_SHA=$(sha256sum "$MINIMAL" | awk '{print $1}')

make_root() {
  local root=$1
  mkdir -p "$root/etc" "$root/boot" "$root/usr/bin" "$root/usr/share/omarchy-arm64" \
    "$root/var/lib/pacman/local" "$root/var/lib/uconsole-omarchy-arm64" \
    "$root/home/alarm/.config/hypr"
  printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$root/etc/os-release"
  printf 'alarm:x:%s:%s:Fixture User:/home/alarm:/bin/bash\n' "$CURRENT_UID" "$CURRENT_GID" > "$root/etc/passwd"
  printf '#!/bin/sh\nexit 0\n' > "$root/usr/bin/omarchy-launch-shell"
  chmod 0755 "$root/usr/bin/omarchy-launch-shell"
  install -m 0644 "$MINIMAL" "$root/home/alarm/.config/hypr/hyprland.lua"

  cat > "$root/var/lib/uconsole-omarchy-arm64/hyprland-selection" <<STATE
target_user=alarm
config_sha256=$MINIMAL_SHA
STATE
  cat > "$root/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" <<'STATE'
userland_version=4.0.0.alpha-3
target_user=alarm
session_activated=no
STATE
  cat > "$root/var/lib/uconsole-omarchy-arm64/user-preparation-alarm" <<'STATE'
target_user=alarm
upstream_commit=d99d4fc6de0bc99d48c9935724fa19d7fb41ae54
historical_migrations_run=no
STATE
  cat > "$root/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE" <<'STATE'
hyprland_owned=no
updates_owned=no
hardware_owned=no
STATE
}

ROOT="$TEST_TMP/root"
make_root "$ROOT"
CHOWN="$REPO_ROOT/tests/helpers/fake-chown.sh"
ARGS=(--root "$ROOT" --user alarm --chown-command "$CHOWN")
CONFIG="$ROOT/home/alarm/.config/hypr/hyprland.lua"
GUARD="$ROOT/usr/local/bin/omarchy-session-arm64"
STATE_FILE="$ROOT/var/lib/uconsole-omarchy-arm64/session-handoff-alarm"

expect_rejected() {
  local label=$1
  shift
  local status=0
  "$ACTIVATOR" "$@" >/dev/null 2>&1
  status=$?
  [[ $status -eq 2 ]] || {
    printf 'Expected %s to be rejected with status 2; got %s\n' "$label" "$status" >&2
    exit 1
  }
}

# Plan must change nothing at all.
"$ACTIVATOR" "${ARGS[@]}" --plan >/dev/null || { printf 'Expected manual plan to pass\n' >&2; exit 1; }
[[ ! -e "$GUARD" ]] || { printf 'Plan installed the guard\n' >&2; exit 1; }
[[ ! -e "$STATE_FILE" ]] || { printf 'Plan wrote handoff state\n' >&2; exit 1; }
cmp -s "$CONFIG" "$MINIMAL" || { printf 'Plan modified the Hyprland configuration\n' >&2; exit 1; }

# Manual apply: bind only, no autostart.
"$ACTIVATOR" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected manual apply to pass\n' >&2; exit 1; }
[[ -x "$GUARD" ]] || { printf 'Manual apply did not install an executable guard\n' >&2; exit 1; }
cmp -s "$GUARD" "$GUARD_SOURCE" || { printf 'Installed guard differs from the reviewed source\n' >&2; exit 1; }
grep -Fq 'hl.bind("SUPER + O"' "$CONFIG" || { printf 'Manual apply did not add the on-demand bind\n' >&2; exit 1; }
grep -Fq 'hl.exec_cmd("omarchy-session-arm64")' "$CONFIG" && { printf 'Manual mode must not autostart the shell\n' >&2; exit 1; }
grep -Fxq 'mode=manual' "$STATE_FILE" || { printf 'Handoff state does not record manual mode\n' >&2; exit 1; }
head -n "$(wc -l < "$MINIMAL")" "$CONFIG" | cmp -s - "$MINIMAL" || { printf 'Activated config does not begin with the exact baseline\n' >&2; exit 1; }

# Reapply must be byte-identical and must not stack a second block.
CONFIG_SHA_BEFORE=$(sha256sum "$CONFIG" | awk '{print $1}')
"$ACTIVATOR" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected idempotent manual reapply to pass\n' >&2; exit 1; }
[[ "$(sha256sum "$CONFIG" | awk '{print $1}')" == "$CONFIG_SHA_BEFORE" ]] || { printf 'Manual reapply was not idempotent\n' >&2; exit 1; }
[[ $(grep -c 'uconsole-omarchy-arm64 session handoff (managed' "$CONFIG") -eq 1 ]] || { printf 'Reapply stacked a duplicate managed block\n' >&2; exit 1; }

# Switching to autostart replaces the block rather than appending one.
"$ACTIVATOR" "${ARGS[@]}" --mode autostart --apply >/dev/null || { printf 'Expected autostart apply to pass\n' >&2; exit 1; }
grep -Fq 'hl.exec_cmd("omarchy-session-arm64")' "$CONFIG" || { printf 'Autostart apply did not add the startup launch\n' >&2; exit 1; }
[[ $(grep -c 'uconsole-omarchy-arm64 session handoff (managed' "$CONFIG") -eq 1 ]] || { printf 'Mode switch stacked a duplicate managed block\n' >&2; exit 1; }
grep -Fxq 'mode=autostart' "$STATE_FILE" || { printf 'Handoff state does not record autostart mode\n' >&2; exit 1; }
grep -Fxq 'display_manager=no' "$STATE_FILE" || { printf 'Handoff state lost the display-manager boundary\n' >&2; exit 1; }
grep -Fxq 'uwsm=no' "$STATE_FILE" || { printf 'Handoff state lost the UWSM boundary\n' >&2; exit 1; }

# Deactivation must restore the byte-exact baseline and leave nothing behind.
"$ACTIVATOR" "${ARGS[@]}" --deactivate >/dev/null || { printf 'Expected deactivate to pass\n' >&2; exit 1; }
cmp -s "$CONFIG" "$MINIMAL" || { printf 'Deactivate did not restore the exact minimal baseline\n' >&2; exit 1; }
[[ ! -e "$GUARD" ]] || { printf 'Deactivate left the guard installed\n' >&2; exit 1; }
[[ ! -e "$STATE_FILE" ]] || { printf 'Deactivate left handoff state behind\n' >&2; exit 1; }
"$ACTIVATOR" "${ARGS[@]}" --deactivate >/dev/null || { printf 'Expected repeated deactivate to be a no-op\n' >&2; exit 1; }

# The shell selection's session_activated claim is read by four separate gates
# as proof that no handoff is enabled, so activation must keep it truthful or an
# activated root could be imaged as an inactive one.
SHELL_SELECTION="$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection"
"$ACTIVATOR" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected apply for activation-claim check to pass\n' >&2; exit 1; }
grep -Fxq 'session_activated=yes' "$SHELL_SELECTION" || {
  printf 'Activation left session_activated stale:\n%s\n' "$(cat "$SHELL_SELECTION")" >&2; exit 1; }
grep -Fxq 'target_user=alarm' "$SHELL_SELECTION" || { printf 'Activation damaged other shell state fields\n' >&2; exit 1; }
grep -Fxq 'userland_version=4.0.0.alpha-3' "$SHELL_SELECTION" || { printf 'Activation damaged the userland version\n' >&2; exit 1; }
"$ACTIVATOR" "${ARGS[@]}" --deactivate >/dev/null || { printf 'Expected deactivate for activation-claim check to pass\n' >&2; exit 1; }
grep -Fxq 'session_activated=no' "$SHELL_SELECTION" || {
  printf 'Deactivation did not clear session_activated:\n%s\n' "$(cat "$SHELL_SELECTION")" >&2; exit 1; }

# A reapply must repair a stale claim rather than short-circuit past it.
"$ACTIVATOR" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected apply before stale-claim repair to pass\n' >&2; exit 1; }
sed 's/^session_activated=yes$/session_activated=no/' "$SHELL_SELECTION" > "$TEST_TMP/shell-selection"
mv "$TEST_TMP/shell-selection" "$SHELL_SELECTION"
"$ACTIVATOR" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected stale-claim reapply to pass\n' >&2; exit 1; }
grep -Fxq 'session_activated=yes' "$SHELL_SELECTION" || { printf 'Reapply did not repair the stale activation claim\n' >&2; exit 1; }

# Deactivation must not delete an unrecognised binary sitting at the guard path.
"$ACTIVATOR" "${ARGS[@]}" --deactivate >/dev/null || { printf 'Expected deactivate before foreign-guard check to pass\n' >&2; exit 1; }
mkdir -p "$(dirname "$GUARD")"
printf '#!/bin/sh\necho not ours\n' > "$GUARD"
chmod 0755 "$GUARD"
expect_rejected 'unrecognised file at the guard path' "${ARGS[@]}" --deactivate
[[ -f "$GUARD" ]] || { printf 'Deactivate removed an unrecognised guard binary\n' >&2; exit 1; }
rm "$GUARD"

# A user-modified configuration is never rewritten.
printf '\n-- user edit\n' >> "$CONFIG"
expect_rejected 'user-modified Hyprland configuration' "${ARGS[@]}" --apply
install -m 0644 "$MINIMAL" "$CONFIG"

# Boundary options stay refused.
expect_rejected 'display manager activation' "${ARGS[@]}" --enable-display-manager --apply
expect_rejected 'UWSM activation' "${ARGS[@]}" --enable-uwsm --apply
expect_rejected 'autologin activation' "${ARGS[@]}" --autologin --apply
expect_rejected 'unknown mode' "${ARGS[@]}" --mode sddm --apply
expect_rejected 'root session owner' --root "$ROOT" --user root --chown-command "$CHOWN" --apply

# Missing or mismatched prerequisite state stops the handoff.
mv "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-alarm" "$TEST_TMP/user-preparation-alarm"
expect_rejected 'missing user preparation state' "${ARGS[@]}" --apply
mv "$TEST_TMP/user-preparation-alarm" "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-alarm"

sed 's/^hyprland_owned=no$/hyprland_owned=yes/' "$ROOT/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE" > "$TEST_TMP/state"
mv "$TEST_TMP/state" "$ROOT/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE"
expect_rejected 'package claiming Hyprland ownership' "${ARGS[@]}" --apply
sed 's/^hyprland_owned=yes$/hyprland_owned=no/' "$ROOT/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE" > "$TEST_TMP/state"
mv "$TEST_TMP/state" "$ROOT/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE"

rm "$ROOT/usr/bin/omarchy-launch-shell"
expect_rejected 'missing shell launcher' "${ARGS[@]}" --apply

# A root that fails the offline-Arch check must stop the transaction outright.
# install_common_die runs inside a command substitution, so without an explicit
# guard the script would continue with an empty root and resolve every
# subsequent path against the host filesystem.
mkdir -p "$TEST_TMP/not-a-root"
expect_rejected 'non-Arch root' --root "$TEST_TMP/not-a-root" --user alarm --chown-command "$CHOWN" --apply
BAD_ROOT_OUTPUT=$("$ACTIVATOR" --root "$TEST_TMP/not-a-root" --user alarm --chown-command "$CHOWN" --apply 2>&1 || true)
# Exactly one error is the assertion that matters. An unguarded root resolution
# still exits non-zero, but only after a second, downstream check fails against
# a host path — so counting errors is what distinguishes stopping at the root
# from continuing past it.
BAD_ROOT_ERRORS=$(printf '%s\n' "$BAD_ROOT_OUTPUT" | grep -c '^ERROR:')
[[ "$BAD_ROOT_ERRORS" -eq 1 ]] || {
  printf 'Expected exactly one error for a rejected root; got %s:\n%s\n' "$BAD_ROOT_ERRORS" "$BAD_ROOT_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$BAD_ROOT_OUTPUT" | grep -Fq 'missing Arch Linux ARM identity' || {
  printf 'Rejected root did not stop at the offline-root check:\n%s\n' "$BAD_ROOT_OUTPUT" >&2
  exit 1
}

printf 'activate-omarchy-session tests: PASS\n'
