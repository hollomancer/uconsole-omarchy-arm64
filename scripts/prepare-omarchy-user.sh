#!/usr/bin/env bash

# Seed only the reviewed Omarchy shell/Foot configuration and historical
# migration baseline into a user on an offline root. Existing target
# configuration or migration state is a hard conflict; this never starts a
# session.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd) || exit 2
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION='plan'
ACTION_SET=0
ROOT=''
TARGET_USER=''
SOURCE_ARCHIVE=''
MIGRATION_LOCK="$REPO_ROOT/config/arm64-overrides/omarchy-migration-baseline.lock"
SHELL_CONFIG="$REPO_ROOT/config/arm64-overrides/shell.json"
EXPECTED_PACKAGE_COMMIT='d99d4fc6de0bc99d48c9935724fa19d7fb41ae54'
EXPECTED_USERLAND_VERSION='4.0.0.alpha-3'
EXPECTED_SHELL_TRANSACTION_SHA256='9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3'
EXPECTED_RUNTIME_POLICY_SHA256='5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d'
EXPECTED_MIGRATION_COUNT=87
EXPECTED_MIGRATION_LOCK_SHA256='bf1cd979738bc9035731e881fae95072d64caf2bacb3705f9a47433a0aa7b143'
EXPECTED_SHELL_SHA256='b8f1995c5fbfe55252463c47f21cce833154f905a92d493a03981a21eac8ac9a'
EXPECTED_FOOT_SHA256='a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf'
EXPECTED_THEME_FOOT_SHA256='d20c424a3e0635011e683d8a379b1e3711abaf61f7d44cf9dd25409a04558667'
EXPECTED_THEME_SHELL_SHA256='1343b48a969352eddb145e5acff00a8505d30f4f4007c4234d593b9d4b4a053b'
INITIAL_THEME='tokyo-night'
INITIAL_THEME_TARGET='/usr/share/omarchy-arm64/themes/tokyo-night'
INITIAL_BACKGROUND_TARGET='/usr/share/omarchy-arm64/themes/tokyo-night/backgrounds/0-winding-road.webp'
CHOWN_COMMAND='chown'

usage() {
  printf '%s\n' \
    'Usage: prepare-omarchy-user.sh --root DIR --user NAME --source-archive FILE [--plan|--apply]' \
    '' \
    'The root must be offline and already contain omarchy-arm64-userland.' \
    'Existing ~/.config/omarchy, ~/.config/foot, or migration state is never overwritten.' \
    'No Hyprland file, service, session, migration script or system update is run.' \
    '--chown-command is a chown-compatible test/build hook; production uses chown.'
}

set_action() {
  local requested=$1
  if [[ $ACTION_SET -eq 1 && "$ACTION" != "$requested" ]]; then install_common_die 'choose exactly one action'; fi
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --plan) set_action plan; shift ;;
    --apply) set_action apply; shift ;;
    --root) (($# >= 2)) || install_common_die '--root requires a directory'; ROOT=$2; shift 2 ;;
    --user) (($# >= 2)) || install_common_die '--user requires a name'; TARGET_USER=$2; shift 2 ;;
    --source-archive) (($# >= 2)) || install_common_die '--source-archive requires a file'; SOURCE_ARCHIVE=$2; shift 2 ;;
    --chown-command) (($# >= 2)) || install_common_die '--chown-command requires a path'; CHOWN_COMMAND=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --activate|--enable-uwsm|--enable-sddm|--run-migrations|--allow-existing|--force|--device|--allow-live-root)
      install_common_die "$1 is forbidden by the preparation boundary"
      ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$TARGET_USER" != root ]] || install_common_die '--user must be a safe non-root Linux account name'
install_common_require_file 'source archive' "$SOURCE_ARCHIVE"
install_common_require_file 'migration baseline lock' "$MIGRATION_LOCK"
install_common_require_file 'ARM shell configuration' "$SHELL_CONFIG"
[[ "$(install_common_sha256 "$MIGRATION_LOCK")" == "$EXPECTED_MIGRATION_LOCK_SHA256" ]] || install_common_die 'migration baseline lock changed'
[[ "$(install_common_sha256 "$SHELL_CONFIG")" == "$EXPECTED_SHELL_SHA256" ]] || install_common_die 'ARM shell configuration changed'

# Reuse the complete fail-closed source audit before trusting migration names or
# hashes from the archive.
"$REPO_ROOT/research/audit-omarchy-activation.sh" --source-archive "$SOURCE_ARCHIVE" >/dev/null || install_common_die 'pinned Omarchy source audit failed'

ROOT=$(install_common_require_offline_arch_root "$ROOT")
PACKAGE_ROOT="$ROOT/usr/share/omarchy-arm64"
PACKAGE_STATE="$PACKAGE_ROOT/ARM64-PACKAGE-STATE"
install_common_require_file 'installed ARM userland state' "$PACKAGE_STATE"
install_common_require_file 'installed ARM shell configuration' "$PACKAGE_ROOT/config/omarchy/shell.json"
install_common_require_file 'installed Foot configuration' "$PACKAGE_ROOT/config/foot/foot.ini"
[[ "$(install_common_sha256 "$PACKAGE_ROOT/config/omarchy/shell.json")" == "$EXPECTED_SHELL_SHA256" ]] || install_common_die 'installed shell configuration differs from reviewed ARM configuration'
[[ "$(install_common_sha256 "$PACKAGE_ROOT/config/foot/foot.ini")" == "$EXPECTED_FOOT_SHA256" ]] || install_common_die 'installed Foot configuration differs from pinned Omarchy configuration'
grep -Fxq "upstream_commit=$EXPECTED_PACKAGE_COMMIT" "$PACKAGE_STATE" || install_common_die 'installed ARM userland has an unexpected upstream commit'
grep -Fxq 'activation=not-enabled' "$PACKAGE_STATE" || install_common_die 'installed ARM userland state is not inactive'
grep -Fxq 'initial_theme=tokyo-night-rendered' "$PACKAGE_STATE" || install_common_die 'installed ARM userland lacks the rendered initial theme state'
grep -Fxq 'terminal_config=home-seed-only' "$PACKAGE_STATE" || install_common_die 'installed ARM userland has an unexpected terminal ownership boundary'
grep -Fxq 'fontconfig=package-owned' "$PACKAGE_STATE" || install_common_die 'installed ARM userland has an unexpected fontconfig boundary'
grep -Fxq 'hyprland_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns Hyprland'
grep -Fxq 'updates_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns updates'
grep -Fxq 'hardware_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns hardware'
[[ -d "$ROOT$INITIAL_THEME_TARGET" && ! -L "$ROOT$INITIAL_THEME_TARGET" ]] || install_common_die 'initial packaged theme is missing or unsafe'
install_common_require_file 'initial packaged background' "$ROOT$INITIAL_BACKGROUND_TARGET"
install_common_require_file 'initial rendered Foot theme' "$ROOT$INITIAL_THEME_TARGET/foot.ini"
install_common_require_file 'initial rendered shell theme' "$ROOT$INITIAL_THEME_TARGET/shell.toml"
[[ "$(install_common_sha256 "$ROOT$INITIAL_THEME_TARGET/foot.ini")" == "$EXPECTED_THEME_FOOT_SHA256" ]] || install_common_die 'initial rendered Foot theme differs'
[[ "$(install_common_sha256 "$ROOT$INITIAL_THEME_TARGET/shell.toml")" == "$EXPECTED_THEME_SHELL_SHA256" ]] || install_common_die 'initial rendered shell theme differs'

SHELL_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection"
install_common_require_file 'installed Omarchy shell selection' "$SHELL_STATE"
grep -Fxq "userland_version=$EXPECTED_USERLAND_VERSION" "$SHELL_STATE" || install_common_die 'Omarchy shell selection has an unexpected userland version'
grep -Fxq "transaction_lock_sha256=$EXPECTED_SHELL_TRANSACTION_SHA256" "$SHELL_STATE" || install_common_die 'Omarchy shell selection has an unexpected official transaction'
grep -Fxq "runtime_policy_sha256=$EXPECTED_RUNTIME_POLICY_SHA256" "$SHELL_STATE" || install_common_die 'Omarchy shell selection has an unexpected runtime boundary'
grep -Fxq "target_user=$TARGET_USER" "$SHELL_STATE" || install_common_die 'Omarchy shell selection belongs to a different user'
grep -Fxq 'home_seeded=no' "$SHELL_STATE" || install_common_die 'Omarchy shell selection already reports a home seed'
grep -Fxq 'session_activated=no' "$SHELL_STATE" || install_common_die 'Omarchy shell selection reports session activation'

PASSWD_FILE="$ROOT/etc/passwd"
install_common_require_file 'target passwd database' "$PASSWD_FILE"
USER_FIELDS=$(awk -F ':' -v wanted="$TARGET_USER" '$1 == wanted { count++; uid=$3; gid=$4; home=$6 } END { if (count == 1) print uid ":" gid ":" home; else exit 1 }' "$PASSWD_FILE") || install_common_die "target user is missing or duplicated: $TARGET_USER"
IFS=':' read -r TARGET_UID TARGET_GID TARGET_HOME <<< "$USER_FIELDS"
[[ "$TARGET_UID" =~ ^[0-9]+$ && "$TARGET_GID" =~ ^[0-9]+$ ]] || install_common_die 'target user has invalid numeric ownership'
((TARGET_UID >= 1000)) || install_common_die 'target user must not be a system account'
[[ "$TARGET_HOME" == "/home/$TARGET_USER" ]] || install_common_die 'target user has an unexpected home'
HOME_ROOT="$ROOT$TARGET_HOME"
[[ -d "$HOME_ROOT" && ! -L "$HOME_ROOT" ]] || install_common_die 'target home is missing or unsafe'

SOURCE_ROOT="omarchy-$EXPECTED_PACKAGE_COMMIT"
MIGRATION_AUDIT_BASE=${TMPDIR:-/tmp}
MIGRATION_AUDIT_BASE=${MIGRATION_AUDIT_BASE%/}
MIGRATION_AUDIT_TMP=$(mktemp -d "$MIGRATION_AUDIT_BASE/uconsole-omarchy-migration-audit.XXXXXX") || install_common_die 'unable to create migration audit directory'
cleanup_migration_audit() {
  case "$MIGRATION_AUDIT_TMP" in
    /tmp/uconsole-omarchy-migration-audit.*|/private/tmp/uconsole-omarchy-migration-audit.*|/var/folders/*/T/uconsole-omarchy-migration-audit.*|/private/var/folders/*/T/uconsole-omarchy-migration-audit.*) rm -rf -- "$MIGRATION_AUDIT_TMP" ;;
    *) printf 'Refusing unsafe migration audit cleanup path: %s\n' "$MIGRATION_AUDIT_TMP" >&2 ;;
  esac
}
trap cleanup_migration_audit EXIT
bsdtar -xf "$SOURCE_ARCHIVE" -C "$MIGRATION_AUDIT_TMP" "$SOURCE_ROOT/migrations" || install_common_die 'unable to extract migration audit inputs'
MIGRATION_COUNT=0
while IFS='|' read -r migration_name migration_sha disposition extra; do
  [[ -n "$migration_name" && "$migration_name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || install_common_die "invalid migration lock row: $migration_name"
  [[ "$migration_name" =~ ^[0-9]+\.sh$ ]] || install_common_die "unsafe migration marker name: $migration_name"
  [[ "$migration_sha" =~ ^[0-9a-f]{64}$ ]] || install_common_die "invalid migration digest: $migration_name"
  [[ "$disposition" == 'baseline-do-not-run' ]] || install_common_die "unsafe migration disposition: $migration_name"
  migration_path="$MIGRATION_AUDIT_TMP/$SOURCE_ROOT/migrations/$migration_name"
  install_common_require_file 'locked migration' "$migration_path"
  observed_sha=$(install_common_sha256 "$migration_path") || install_common_die "unable to hash migration: $migration_name"
  [[ "$observed_sha" == "$migration_sha" ]] || install_common_die "migration digest mismatch: $migration_name"
  MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
done < "$MIGRATION_LOCK"
[[ $MIGRATION_COUNT -eq $EXPECTED_MIGRATION_COUNT ]] || install_common_die "expected $EXPECTED_MIGRATION_COUNT baseline migrations; observed $MIGRATION_COUNT"
cleanup_migration_audit
trap - EXIT

CONFIG_DIR="$HOME_ROOT/.config/omarchy"
TARGET_CONFIG="$CONFIG_DIR/shell.json"
FOOT_CONFIG_DIR="$HOME_ROOT/.config/foot"
TARGET_FOOT_CONFIG="$FOOT_CONFIG_DIR/foot.ini"
MIGRATION_DIR="$HOME_ROOT/.local/state/omarchy/migrations"
CURRENT_DIR="$HOME_ROOT/.local/state/omarchy/current"
STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/user-preparation-$TARGET_USER"

markers_match() {
  [[ -d "$MIGRATION_DIR" && ! -L "$MIGRATION_DIR" ]] || return 1
  local observed=''
  local expected=''
  observed=$(find "$MIGRATION_DIR" -maxdepth 1 -type f -size 0 -exec basename {} \; | LC_ALL=C sort) || return 1
  expected=$(awk -F '|' '$0 !~ /^#/ && NF { print $1 }' "$MIGRATION_LOCK" | LC_ALL=C sort) || return 1
  [[ "$observed" == "$expected" ]] || return 1
  [[ $(find "$MIGRATION_DIR" -mindepth 1 -maxdepth 1 ! -type f | wc -l | tr -d ' ') -eq 0 ]]
}

existing_seed_matches() {
  [[ -f "$TARGET_CONFIG" && ! -L "$TARGET_CONFIG" ]] || return 1
  [[ "$(install_common_sha256 "$TARGET_CONFIG")" == "$EXPECTED_SHELL_SHA256" ]] || return 1
  [[ -f "$TARGET_FOOT_CONFIG" && ! -L "$TARGET_FOOT_CONFIG" ]] || return 1
  [[ "$(install_common_sha256 "$TARGET_FOOT_CONFIG")" == "$EXPECTED_FOOT_SHA256" ]] || return 1
  markers_match || return 1
  [[ -d "$CURRENT_DIR" && ! -L "$CURRENT_DIR" ]] || return 1
  [[ -L "$CURRENT_DIR/theme" && "$(readlink "$CURRENT_DIR/theme")" == "$INITIAL_THEME_TARGET" ]] || return 1
  [[ -L "$CURRENT_DIR/background" && "$(readlink "$CURRENT_DIR/background")" == "$INITIAL_BACKGROUND_TARGET" ]] || return 1
  [[ -f "$CURRENT_DIR/theme.name" && ! -L "$CURRENT_DIR/theme.name" ]] || return 1
  [[ "$(<"$CURRENT_DIR/theme.name")" == "$INITIAL_THEME" ]] || return 1
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  grep -Fxq "target_user=$TARGET_USER" "$STATE_FILE" || return 1
  grep -Fxq "migration_count=$EXPECTED_MIGRATION_COUNT" "$STATE_FILE" || return 1
  grep -Fxq "migration_lock_sha256=$EXPECTED_MIGRATION_LOCK_SHA256" "$STATE_FILE" || return 1
  grep -Fxq "foot_sha256=$EXPECTED_FOOT_SHA256" "$STATE_FILE" || return 1
  grep -Fxq 'historical_migrations_run=no' "$STATE_FILE" || return 1
  grep -Fxq 'session_modified=no' "$STATE_FILE" || return 1
  grep -Fxq "initial_theme=$INITIAL_THEME" "$STATE_FILE" || return 1
}

if [[ -e "$CONFIG_DIR" || -e "$FOOT_CONFIG_DIR" || -e "$MIGRATION_DIR" || -e "$CURRENT_DIR" || -e "$STATE_FILE" ]]; then
  if existing_seed_matches; then
    EXISTING='exact-idempotent'
  else
    install_common_die 'existing Omarchy, Foot, migration, visual, or preparation state conflicts with the exact seed; no files were changed'
  fi
else
  EXISTING='none'
fi

printf '%s\n' \
  "[PASS] offline root          $ROOT" \
  "[PASS] installed userland   commit=$EXPECTED_PACKAGE_COMMIT activation=not-enabled" \
  "[PASS] user boundary        $TARGET_USER uid=$TARGET_UID gid=$TARGET_GID home=$TARGET_HOME existing=$EXISTING" \
  "[PASS] migration baseline   count=$MIGRATION_COUNT disposition=baseline-do-not-run" \
  "[PASS] shell configuration  sha256=$EXPECTED_SHELL_SHA256 plugins fail-closed" \
  "[PASS] Foot configuration   sha256=$EXPECTED_FOOT_SHA256 theme=Tokyo-Night-rendered" \
  "[PASS] initial visual state theme=$INITIAL_THEME background=${INITIAL_BACKGROUND_TARGET##*/}" \
  '' \
  "Action: $ACTION" \
  'Session activation: no' \
  'Hyprland modification: no' \
  'Historical migration execution: no'

if [[ "$ACTION" == 'plan' || "$EXISTING" == 'exact-idempotent' ]]; then
  [[ "$ACTION" != 'plan' ]] || printf 'Plan complete. No user, session, service, package, update or boot file was changed.\n'
  [[ "$EXISTING" != 'exact-idempotent' ]] || printf '[PASS] existing preparation is byte-for-byte idempotent; no files changed.\n'
  exit 0
fi

[[ -w "$HOME_ROOT" && -w "$STATE_DIR" ]] || install_common_die 'offline home and project state directory must be writable'
if [[ "$CHOWN_COMMAND" == */* ]]; then
  [[ -x "$CHOWN_COMMAND" ]] || install_common_die "chown command is not executable: $CHOWN_COMMAND"
else
  command -v "$CHOWN_COMMAND" >/dev/null 2>&1 || install_common_die "chown command not found: $CHOWN_COMMAND"
fi

mkdir -p "$HOME_ROOT/.config" "$HOME_ROOT/.local/state/omarchy" || install_common_fail 'unable to create user seed parents'
[[ ! -e "$CONFIG_DIR" && ! -e "$FOOT_CONFIG_DIR" && ! -e "$MIGRATION_DIR" && ! -e "$CURRENT_DIR" ]] || install_common_fail 'user seed conflict appeared during transaction'
mkdir "$CONFIG_DIR" || install_common_fail 'unable to create Omarchy config directory'
mkdir "$FOOT_CONFIG_DIR" || install_common_fail 'unable to create Foot config directory'
MIGRATION_STAGE="$HOME_ROOT/.local/state/omarchy/.migrations-arm64.$$"
mkdir "$MIGRATION_STAGE" || install_common_fail 'unable to create migration marker stage'
while IFS='|' read -r migration_name _ disposition _; do
  [[ -n "$migration_name" && "$migration_name" != \#* ]] || continue
  [[ "$disposition" == 'baseline-do-not-run' ]] || install_common_fail 'migration policy changed during transaction'
  : > "$MIGRATION_STAGE/$migration_name" || install_common_fail "unable to create migration marker: $migration_name"
done < "$MIGRATION_LOCK"
chmod 0700 "$CONFIG_DIR" "$FOOT_CONFIG_DIR" "$MIGRATION_STAGE" || install_common_fail 'unable to set user directory modes'
install -m 0644 "$SHELL_CONFIG" "$TARGET_CONFIG" || install_common_fail 'unable to install reviewed shell configuration'
install -m 0644 "$PACKAGE_ROOT/config/foot/foot.ini" "$TARGET_FOOT_CONFIG" || install_common_fail 'unable to install pinned Foot configuration'
chmod 0600 "$MIGRATION_STAGE"/* || install_common_fail 'unable to set migration marker modes'
mv "$MIGRATION_STAGE" "$MIGRATION_DIR" || install_common_fail 'unable to publish migration baseline'
CURRENT_STAGE="$HOME_ROOT/.local/state/omarchy/.current-arm64.$$"
mkdir "$CURRENT_STAGE" || install_common_fail 'unable to create visual-state stage'
ln -s "$INITIAL_THEME_TARGET" "$CURRENT_STAGE/theme" || install_common_fail 'unable to stage initial theme link'
ln -s "$INITIAL_BACKGROUND_TARGET" "$CURRENT_STAGE/background" || install_common_fail 'unable to stage initial background link'
printf '%s\n' "$INITIAL_THEME" > "$CURRENT_STAGE/theme.name" || install_common_fail 'unable to stage initial theme name'
chmod 0700 "$CURRENT_STAGE" || install_common_fail 'unable to set visual-state mode'
chmod 0600 "$CURRENT_STAGE/theme.name" || install_common_fail 'unable to set theme-name mode'
mv "$CURRENT_STAGE" "$CURRENT_DIR" || install_common_fail 'unable to publish initial visual state'

"$CHOWN_COMMAND" -R "$TARGET_UID:$TARGET_GID" "$CONFIG_DIR" "$FOOT_CONFIG_DIR" "$HOME_ROOT/.local/state/omarchy" || install_common_fail 'unable to set user seed ownership'

STATE_TMP="$STATE_DIR/.user-preparation-$TARGET_USER.$$"
{
  printf 'target_user=%s\n' "$TARGET_USER"
  printf 'upstream_commit=%s\n' "$EXPECTED_PACKAGE_COMMIT"
  printf 'shell_sha256=%s\n' "$EXPECTED_SHELL_SHA256"
  printf 'foot_sha256=%s\n' "$EXPECTED_FOOT_SHA256"
  printf 'migration_count=%s\n' "$EXPECTED_MIGRATION_COUNT"
  printf 'migration_lock_sha256=%s\n' "$EXPECTED_MIGRATION_LOCK_SHA256"
  printf 'historical_migrations_run=no\n'
  printf 'initial_theme=%s\n' "$INITIAL_THEME"
  printf 'session_modified=no\n'
  printf 'activation=no\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage preparation state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set preparation state mode'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish preparation state'

existing_seed_matches || install_common_fail 'published user preparation does not verify'
printf '%s\n' \
  "[PASS] user shell seed       $TARGET_HOME/.config/omarchy/shell.json" \
  "[PASS] user Foot seed        $TARGET_HOME/.config/foot/foot.ini" \
  "[PASS] migration markers    $EXPECTED_MIGRATION_COUNT zero-byte baseline markers; no migration executed" \
  "[PASS] initial visual state $INITIAL_THEME with packaged background" \
  "[PASS] preparation state    /var/lib/uconsole-omarchy-arm64/user-preparation-$TARGET_USER" \
  '[PASS] activation boundary  Hyprland and session startup remain unchanged'
