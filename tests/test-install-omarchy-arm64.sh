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
INSTALLER="$REPO_ROOT/scripts/install-omarchy-arm64.sh"
POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-staged-paths.lock"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-omarchy-stage-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-omarchy-stage-test.*|/private/tmp/uconsole-omarchy-stage-test.*|/var/folders/*/T/uconsole-omarchy-stage-test.*|/private/var/folders/*/T/uconsole-omarchy-stage-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

COMMIT='d99d4fc6de0bc99d48c9935724fa19d7fb41ae54'
ARCHIVE_ROOT="omarchy-$COMMIT"
SOURCE_DIR="$TEST_TMP/source/$ARCHIVE_ROOT"
mkdir -p "$SOURCE_DIR/bin" "$SOURCE_DIR/config/hypr" "$SOURCE_DIR/config/omarchy" "$SOURCE_DIR/shell" "$SOURCE_DIR/themes" \
  "$SOURCE_DIR/applications" "$SOURCE_DIR/default/hypr" "$SOURCE_DIR/default/themed" "$SOURCE_DIR/default/foot"
printf '4.0.0.alpha\n' > "$SOURCE_DIR/version"
printf '%s\n' 'Permission is hereby granted, free of charge, to any person obtaining a copy.' > "$SOURCE_DIR/LICENSE"
printf '#!/usr/bin/env bash\n' > "$SOURCE_DIR/bin/omarchy-version"
printf 'fixture config\n' > "$SOURCE_DIR/config/hypr/hyprland.lua"
printf '{}\n' > "$SOURCE_DIR/config/omarchy/shell.json"
printf 'fixture shell\n' > "$SOURCE_DIR/shell/shell.qml"
printf 'fixture defaults\n' > "$SOURCE_DIR/default/hypr/omarchy.lua"
printf 'theme\n' > "$SOURCE_DIR/themes/fixture"
printf 'app\n' > "$SOURCE_DIR/applications/fixture"
printf 'template\n' > "$SOURCE_DIR/default/themed/fixture"
printf 'terminal\n' > "$SOURCE_DIR/default/foot/fixture"
printf 'png\n' > "$SOURCE_DIR/icon.png"
printf 'icon\n' > "$SOURCE_DIR/icon.txt"
printf 'svg\n' > "$SOURCE_DIR/logo.svg"
printf 'logo\n' > "$SOURCE_DIR/logo.txt"
for number in $(seq 1 1001); do printf 'audit %s\n' "$number" > "$SOURCE_DIR/bin/audit-$number"; done
ARCHIVE="$TEST_TMP/omarchy.tar.gz"
bsdtar -czf "$ARCHIVE" -C "$TEST_TMP/source" "$ARCHIVE_ROOT"
ARCHIVE_SHA=$(sha256_file "$ARCHIVE")
if stat -c '%s' "$ARCHIVE" >/dev/null 2>&1; then ARCHIVE_SIZE=$(stat -c '%s' "$ARCHIVE"); else ARCHIVE_SIZE=$(stat -f '%z' "$ARCHIVE"); fi
SOURCE_LOCK="$TEST_TMP/source.lock"
printf 'omarchy|4.0.0.alpha|%s|%s|%s|%s\n' "$COMMIT" "$ARCHIVE_SHA" "$ARCHIVE_ROOT" "$ARCHIVE_SIZE" > "$SOURCE_LOCK"

ROOT="$TEST_TMP/root"
mkdir -p "$ROOT/etc" "$ROOT/boot" "$ROOT/var/lib/pacman/local" "$ROOT/var/lib/uconsole-omarchy-arm64" "$ROOT/home/alarm" "$ROOT/usr/bin"
printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$ROOT/etc/os-release"
printf 'alarm:x:1000:1000:Fixture User:/home/alarm:/bin/bash\n' > "$ROOT/etc/passwd"
cat > "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" <<'STATE'
hyprland_version=0.56.1-3
package_lock_sha256=fixture
config_sha256=fixture
target_user=alarm
session_start=start-hyprland
uwsm_enabled=no
STATE

ARGS=(--root "$ROOT" --user alarm --source-archive "$ARCHIVE" --source-lock "$SOURCE_LOCK" --path-policy "$POLICY")
PLAN_OUTPUT=""
if ! PLAN_OUTPUT=$("$INSTALLER" "${ARGS[@]}" --plan); then
  printf '%s\n' "$PLAN_OUTPUT" >&2
  printf 'Expected Omarchy staging plan fixture to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -Fq 'It will not make an Omarchy session runnable.' || { printf 'Plan did not describe inactive result\n' >&2; exit 1; }
[[ ! -e "$ROOT/usr/share/uconsole-omarchy-arm64" ]] || { printf 'Plan staged source\n' >&2; exit 1; }

"$INSTALLER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected Omarchy staging fixture to pass\n' >&2; exit 1; }
DEST="$ROOT/usr/share/uconsole-omarchy-arm64/upstream/$COMMIT"
[[ -f "$DEST/shell/shell.qml" ]] || { printf 'Staged shell missing\n' >&2; exit 1; }
[[ -f "$DEST/ACTIVATION-BLOCKED.md" ]] || { printf 'Activation notice missing\n' >&2; exit 1; }
[[ -f "$DEST/SOURCE-MANIFEST.sha256" ]] || { printf 'Source manifest missing\n' >&2; exit 1; }
[[ ! -e "$ROOT/usr/bin/omarchy" ]] || { printf 'Omarchy command was unexpectedly activated\n' >&2; exit 1; }
[[ ! -e "$ROOT/home/alarm/.config/omarchy" ]] || { printf 'User config was unexpectedly seeded\n' >&2; exit 1; }
grep -Fq 'activation=blocked' "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-source-selection" || { printf 'Blocked state missing\n' >&2; exit 1; }

"$INSTALLER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected idempotent Omarchy staging re-run to pass\n' >&2; exit 1; }

printf 'modified\n' >> "$DEST/shell/shell.qml"
MODIFIED_STATUS=0
"$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
MODIFIED_STATUS=$?
[[ $MODIFIED_STATUS -eq 2 ]] || { printf 'Expected modified staged source to be rejected\n' >&2; exit 1; }

printf 'tamper\n' >> "$ARCHIVE"
TAMPER_STATUS=0
"$INSTALLER" "${ARGS[@]}" --plan >/dev/null 2>&1
TAMPER_STATUS=$?
[[ $TAMPER_STATUS -eq 2 ]] || { printf 'Expected tampered source archive to be rejected\n' >&2; exit 1; }

ACTIVATE_STATUS=0
"$INSTALLER" "${ARGS[@]}" --activate >/dev/null 2>&1
ACTIVATE_STATUS=$?
[[ $ACTIVATE_STATUS -eq 2 ]] || { printf 'Expected activation to be rejected\n' >&2; exit 1; }

printf 'install-omarchy-arm64 inert staging tests: PASS\n'
