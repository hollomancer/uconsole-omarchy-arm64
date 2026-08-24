#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
PREPARER="$REPO_ROOT/scripts/prepare-omarchy-user.sh"
PACKAGE=${OMARCHY_USERLAND_PACKAGE:-/private/tmp/uconsole-omarchy-userland-build-7a-20260824/omarchy-arm64-userland-4.0.0.alpha-3-any.pkg.tar.xz}
SOURCE_ARCHIVE=${OMARCHY_SOURCE_ARCHIVE:-/private/tmp/omarchy-d99d4fc6.tar.gz}

if [[ ! -f "$PACKAGE" || ! -f "$SOURCE_ARCHIVE" ]]; then
  printf 'prepare Omarchy user tests: SKIP (set OMARCHY_USERLAND_PACKAGE and OMARCHY_SOURCE_ARCHIVE)\n'
  exit 0
fi

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-omarchy-user-seed-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-omarchy-user-seed-test.*|/private/tmp/uconsole-omarchy-user-seed-test.*|/var/folders/*/T/uconsole-omarchy-user-seed-test.*|/private/var/folders/*/T/uconsole-omarchy-user-seed-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

make_root() {
  local root=$1
  mkdir -p "$root/etc" "$root/boot" "$root/var/lib/pacman/local" "$root/var/lib/uconsole-omarchy-arm64" "$root/home/alarm"
  printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$root/etc/os-release"
  printf 'alarm:x:1000:1000:Fixture User:/home/alarm:/bin/bash\n' > "$root/etc/passwd"
  bsdtar --no-same-owner -xf "$PACKAGE" -C "$root"
  cat > "$root/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" <<'STATE'
userland_version=4.0.0.alpha-3
userland_sha256=4824a5b829cf6633e0d329307341398353fe14881c9642730e96bb7c31d93b71
upstream_commit=d99d4fc6de0bc99d48c9935724fa19d7fb41ae54
direct_lock_sha256=019a79e470a26a7b3c34adb5209f02269eca3cb4df78e70a15aa41619f097159
transaction_lock_sha256=9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3
transaction_packages=24
runtime_policy_sha256=5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d
runtime_commands=51
target_user=alarm
home_seeded=no
session_activated=no
uwsm_enabled=no
hardware_owned=no
updates_owned=no
STATE
}

ROOT="$TEST_TMP/root"
make_root "$ROOT"
ARGS=(--root "$ROOT" --user alarm --source-archive "$SOURCE_ARCHIVE" --chown-command "$REPO_ROOT/tests/helpers/fake-chown.sh")
"$PREPARER" "${ARGS[@]}" --plan >/dev/null || { printf 'Expected preparation plan to pass\n' >&2; exit 1; }
[[ ! -e "$ROOT/home/alarm/.config/omarchy" ]] || { printf 'Plan changed user config\n' >&2; exit 1; }
"$PREPARER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected preparation apply to pass\n' >&2; exit 1; }
cmp -s "$ROOT/home/alarm/.config/omarchy/shell.json" "$REPO_ROOT/config/arm64-overrides/shell.json" || { printf 'Seeded shell config differs\n' >&2; exit 1; }
cmp -s "$ROOT/home/alarm/.config/foot/foot.ini" "$REPO_ROOT/config/arm64-overrides/foot.ini" || { printf 'Seeded Foot config differs\n' >&2; exit 1; }
[[ $(find "$ROOT/home/alarm/.local/state/omarchy/migrations" -maxdepth 1 -type f -size 0 | wc -l | tr -d ' ') -eq 87 ]] || { printf 'Migration baseline marker count differs\n' >&2; exit 1; }
grep -Fxq 'historical_migrations_run=no' "$ROOT/var/lib/uconsole-omarchy-arm64/user-preparation-alarm" || { printf 'No-run state missing\n' >&2; exit 1; }
[[ $(readlink "$ROOT/home/alarm/.local/state/omarchy/current/theme") == '/usr/share/omarchy-arm64/themes/tokyo-night' ]] || { printf 'Initial theme link differs\n' >&2; exit 1; }
[[ $(readlink "$ROOT/home/alarm/.local/state/omarchy/current/background") == '/usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp' ]] || { printf 'Initial background link differs\n' >&2; exit 1; }
"$PREPARER" "${ARGS[@]}" --apply >/dev/null || { printf 'Expected idempotent preparation apply to pass\n' >&2; exit 1; }

printf 'conflict\n' >> "$ROOT/home/alarm/.config/omarchy/shell.json"
"$PREPARER" "${ARGS[@]}" --plan >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected changed user config to be rejected\n' >&2; exit 1; }

FOOT_CONFLICT_ROOT="$TEST_TMP/foot-conflict-root"
make_root "$FOOT_CONFLICT_ROOT"
mkdir -p "$FOOT_CONFLICT_ROOT/home/alarm/.config/foot"
printf 'existing\n' > "$FOOT_CONFLICT_ROOT/home/alarm/.config/foot/foot.ini"
"$PREPARER" --root "$FOOT_CONFLICT_ROOT" --user alarm --source-archive "$SOURCE_ARCHIVE" --chown-command "$REPO_ROOT/tests/helpers/fake-chown.sh" --plan >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected pre-existing Foot configuration to be rejected\n' >&2; exit 1; }

CONFLICT_ROOT="$TEST_TMP/conflict-root"
make_root "$CONFLICT_ROOT"
mkdir -p "$CONFLICT_ROOT/home/alarm/.config/omarchy"
printf 'existing\n' > "$CONFLICT_ROOT/home/alarm/.config/omarchy/existing.conf"
"$PREPARER" --root "$CONFLICT_ROOT" --user alarm --source-archive "$SOURCE_ARCHIVE" --chown-command "$REPO_ROOT/tests/helpers/fake-chown.sh" --plan >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected pre-existing Omarchy directory to be rejected\n' >&2; exit 1; }

"$PREPARER" "${ARGS[@]}" --activate >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected activation to be rejected\n' >&2; exit 1; }
printf 'prepare Omarchy user tests: PASS\n'
