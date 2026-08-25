#!/usr/bin/env bash

# The reviewed Phase 5 session handoff: give the existing minimal Hyprland
# session exactly one way to reach the Omarchy shell, and keep that reversible.
#
# This is the only place the compositor is allowed to learn about Omarchy. It
# adds a managed block to the user's hyprland.lua and installs a project-owned
# launch guard. It does not enable autologin, a display manager, UWSM, a
# systemd unit, upstream autostart, migrations or any update path.
#
# Two stages, because a shell that wedges the session is expensive to recover:
#
#   --mode manual     (default) on-demand bind only; boot still lands in the
#                     minimal compositor
#   --mode autostart  start the shell with the session; select only after the
#                     manual stage has passed on hardware
#
# --deactivate restores the byte-exact minimal configuration and removes the
# guard, so a failed activation is always one command from a known-good session.

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd) || exit 2
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION='plan'
ACTION_SET=0
ROOT=''
TARGET_USER=''
MODE='manual'
CHOWN_COMMAND='chown'

SESSION_DIR="$REPO_ROOT/config/omarchy-session"
GUARD_SOURCE="$SESSION_DIR/omarchy-session-arm64"
MINIMAL_CONFIG="$REPO_ROOT/config/hyprland/minimal.lua"

# The compositor baseline this handoff is allowed to extend. Any other
# hyprland.lua is a user configuration and is never rewritten.
EXPECTED_MINIMAL_SHA256='f944368040661e3d88746e6c521c978a85e5b5beaeb62cf30ef460548adf0b60'
EXPECTED_USERLAND_VERSION='4.0.0.alpha-3'
EXPECTED_PACKAGE_COMMIT='d99d4fc6de0bc99d48c9935724fa19d7fb41ae54'

GUARD_TARGET='/usr/local/bin/omarchy-session-arm64'

usage() {
  printf '%s\n' \
    'Usage: activate-omarchy-session.sh --root DIR --user NAME [--plan|--apply|--deactivate]' \
    '                                   [--mode manual|autostart]' \
    '' \
    'Adds the reviewed Omarchy shell handoff to an existing minimal Hyprland' \
    'session on an offline root. Requires the exact Hyprland, Omarchy shell and' \
    'inactive user-preparation states.' \
    '' \
    'No display manager, autologin, UWSM, systemd unit, upstream autostart,' \
    'migration or update path is enabled by any mode.' \
    '--chown-command is a chown-compatible test hook; production uses chown.'
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
    --deactivate) set_action deactivate; shift ;;
    --root) (($# >= 2)) || install_common_die '--root requires a directory'; ROOT=$2; shift 2 ;;
    --user) (($# >= 2)) || install_common_die '--user requires a name'; TARGET_USER=$2; shift 2 ;;
    --mode) (($# >= 2)) || install_common_die '--mode requires manual or autostart'; MODE=$2; shift 2 ;;
    --chown-command) (($# >= 2)) || install_common_die '--chown-command requires a path'; CHOWN_COMMAND=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --enable-uwsm|--enable-sddm|--enable-display-manager|--autologin|--run-migrations|--force|--device|--allow-live-root)
      install_common_die "$1 is forbidden by the session handoff boundary"
      ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ "$MODE" == 'manual' || "$MODE" == 'autostart' ]] || install_common_die '--mode must be manual or autostart'
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$TARGET_USER" != root ]] || install_common_die '--user must be a safe non-root Linux account name'

HANDOFF_SOURCE="$SESSION_DIR/handoff-$MODE.lua"
install_common_require_file 'session guard source' "$GUARD_SOURCE"
install_common_require_file 'session handoff block' "$HANDOFF_SOURCE"
install_common_require_file 'minimal Hyprland configuration' "$MINIMAL_CONFIG"
[[ "$(install_common_sha256 "$MINIMAL_CONFIG")" == "$EXPECTED_MINIMAL_SHA256" ]] || install_common_die 'minimal Hyprland configuration changed; re-review the handoff baseline'

ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"

# Every prerequisite layer must already be exactly as its own transaction left
# it. The handoff extends that state; it never repairs or reinterprets it.
HYPRLAND_STATE="$STATE_DIR/hyprland-selection"
install_common_require_file 'Hyprland selection state' "$HYPRLAND_STATE"
grep -Fxq "target_user=$TARGET_USER" "$HYPRLAND_STATE" || install_common_die 'Hyprland state belongs to a different user'
grep -Fxq "config_sha256=$EXPECTED_MINIMAL_SHA256" "$HYPRLAND_STATE" || install_common_die 'installed Hyprland configuration is not the reviewed minimal baseline'

SHELL_STATE="$STATE_DIR/omarchy-shell-selection"
install_common_require_file 'Omarchy shell selection state' "$SHELL_STATE"
grep -Fxq "target_user=$TARGET_USER" "$SHELL_STATE" || install_common_die 'Omarchy shell selection belongs to a different user'
grep -Fxq "userland_version=$EXPECTED_USERLAND_VERSION" "$SHELL_STATE" || install_common_die 'Omarchy shell selection has an unexpected userland version'
grep -Eq '^session_activated=(yes|no)$' "$SHELL_STATE" || install_common_die 'Omarchy shell selection lacks a session_activated field'

USER_STATE="$STATE_DIR/user-preparation-$TARGET_USER"
install_common_require_file 'Omarchy user preparation state' "$USER_STATE"
grep -Fxq "target_user=$TARGET_USER" "$USER_STATE" || install_common_die 'user preparation belongs to a different user'
grep -Fxq "upstream_commit=$EXPECTED_PACKAGE_COMMIT" "$USER_STATE" || install_common_die 'user preparation has an unexpected upstream commit'
grep -Fxq 'historical_migrations_run=no' "$USER_STATE" || install_common_die 'user preparation reports executed migrations'

PACKAGE_STATE="$ROOT/usr/share/omarchy-arm64/ARM64-PACKAGE-STATE"
install_common_require_file 'installed ARM userland state' "$PACKAGE_STATE"
grep -Fxq 'hyprland_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns Hyprland'
grep -Fxq 'updates_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns updates'
grep -Fxq 'hardware_owned=no' "$PACKAGE_STATE" || install_common_die 'installed package unexpectedly owns hardware'
install_common_require_file 'installed shell launcher' "$ROOT/usr/bin/omarchy-launch-shell"

PASSWD_FILE="$ROOT/etc/passwd"
install_common_require_file 'target passwd database' "$PASSWD_FILE"
USER_FIELDS=$(awk -F ':' -v wanted="$TARGET_USER" '$1 == wanted { count++; uid=$3; gid=$4; home=$6 } END { if (count == 1) print uid ":" gid ":" home; else exit 1 }' "$PASSWD_FILE") || install_common_die "target user is missing or duplicated: $TARGET_USER"
IFS=':' read -r TARGET_UID TARGET_GID TARGET_HOME <<< "$USER_FIELDS"
[[ "$TARGET_UID" =~ ^[0-9]+$ && "$TARGET_GID" =~ ^[0-9]+$ ]] || install_common_die 'target user has invalid numeric ownership'
((TARGET_UID >= 1000)) || install_common_die 'root cannot own the graphical session'
[[ "$TARGET_HOME" == "/home/$TARGET_USER" ]] || install_common_die 'target user has an unexpected home'

CONFIG_TARGET="$ROOT$TARGET_HOME/.config/hypr/hyprland.lua"
install_common_require_file 'installed Hyprland configuration' "$CONFIG_TARGET"
GUARD_PATH="$ROOT$GUARD_TARGET"
STATE_FILE="$STATE_DIR/session-handoff-$TARGET_USER"

# The activated configuration is the reviewed baseline followed by exactly one
# managed block, so both directions are byte-verifiable rather than parsed.
ACTIVATED_TMP=$(mktemp) || install_common_die 'unable to stage the expected activated configuration'
cleanup_staging() { rm -f -- "$ACTIVATED_TMP"; }
trap cleanup_staging EXIT
cat "$MINIMAL_CONFIG" "$HANDOFF_SOURCE" > "$ACTIVATED_TMP" || install_common_die 'unable to render the expected activated configuration'
EXPECTED_ACTIVATED_SHA256=$(install_common_sha256 "$ACTIVATED_TMP") || install_common_die 'unable to hash the expected activated configuration'
EXPECTED_GUARD_SHA256=$(install_common_sha256 "$GUARD_SOURCE") || install_common_die 'unable to hash the session guard'
OBSERVED_CONFIG_SHA256=$(install_common_sha256 "$CONFIG_TARGET") || install_common_die 'unable to hash the installed Hyprland configuration'

# The shell selection state carries session_activated as the project-wide claim
# that no handoff is enabled. Four separate gates read it — build-image.sh's
# prepared-image check among them — so leaving it at 'no' after activation would
# let an activated root be imaged as an inactive one. Keep it truthful in both
# directions.
set_shell_activation() {
  local value=$1
  local staged="$STATE_DIR/.omarchy-shell-selection.$$"
  awk -v v="$value" '
    /^session_activated=/ { print "session_activated=" v; seen=1; next }
    { print }
    END { if (!seen) exit 1 }
  ' "$SHELL_STATE" > "$staged" || { rm -f -- "$staged"; return 1; }
  chmod 0644 "$staged" || { rm -f -- "$staged"; return 1; }
  mv "$staged" "$SHELL_STATE" || { rm -f -- "$staged"; return 1; }
  grep -Fxq "session_activated=$value" "$SHELL_STATE"
}

guard_installed_exactly() {
  [[ -f "$GUARD_PATH" && ! -L "$GUARD_PATH" ]] || return 1
  [[ "$(install_common_sha256 "$GUARD_PATH")" == "$EXPECTED_GUARD_SHA256" ]] || return 1
  [[ -x "$GUARD_PATH" ]]
}

state_matches_mode() {
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  grep -Fxq "target_user=$TARGET_USER" "$STATE_FILE" || return 1
  grep -Fxq "mode=$MODE" "$STATE_FILE" || return 1
  grep -Fxq "config_sha256=$EXPECTED_ACTIVATED_SHA256" "$STATE_FILE" || return 1
  grep -Fxq "guard_sha256=$EXPECTED_GUARD_SHA256" "$STATE_FILE" || return 1
}

# Classify the current session state before deciding anything. An unrecognised
# configuration is always a hard stop: this transaction owns only the exact
# baseline and the exact blocks it writes.
if [[ "$OBSERVED_CONFIG_SHA256" == "$EXPECTED_MINIMAL_SHA256" ]]; then
  CURRENT='baseline'
elif [[ "$OBSERVED_CONFIG_SHA256" == "$EXPECTED_ACTIVATED_SHA256" ]]; then
  CURRENT='activated-this-mode'
else
  OTHER_MODE='manual'
  [[ "$MODE" == 'manual' ]] && OTHER_MODE='autostart'
  OTHER_TMP=$(mktemp) || install_common_die 'unable to stage the alternate mode configuration'
  cat "$MINIMAL_CONFIG" "$SESSION_DIR/handoff-$OTHER_MODE.lua" > "$OTHER_TMP" || install_common_die 'unable to render the alternate mode configuration'
  OTHER_SHA256=$(install_common_sha256 "$OTHER_TMP") || install_common_die 'unable to hash the alternate mode configuration'
  rm -f -- "$OTHER_TMP"
  if [[ "$OBSERVED_CONFIG_SHA256" == "$OTHER_SHA256" ]]; then
    CURRENT="activated-$OTHER_MODE"
  else
    CURRENT='unknown'
  fi
fi

[[ "$CURRENT" != 'unknown' ]] || install_common_die 'installed Hyprland configuration is neither the reviewed baseline nor a managed handoff; refusing to modify user configuration'

printf '%s\n' \
  "[PASS] offline root          $ROOT" \
  "[PASS] compositor baseline  minimal Hyprland sha256=$EXPECTED_MINIMAL_SHA256" \
  "[PASS] shell runtime        omarchy-arm64-userland $EXPECTED_USERLAND_VERSION at $EXPECTED_PACKAGE_COMMIT" \
  "[PASS] user boundary        $TARGET_USER uid=$TARGET_UID gid=$TARGET_GID home=$TARGET_HOME" \
  "[PASS] current session      $CURRENT" \
  "[PASS] requested mode       $MODE" \
  '' \
  "Action: $ACTION" \
  'Display manager: no' \
  'Autologin: no' \
  'UWSM: no' \
  'Systemd unit: no' \
  'Upstream autostart: no' \
  'Migration execution: no'

if [[ "$ACTION" == 'plan' ]]; then
  printf 'Plan complete. No configuration, guard, service, package or boot file was changed.\n'
  exit 0
fi

[[ -w "$STATE_DIR" ]] || install_common_die 'project state directory must be writable'
if [[ "$CHOWN_COMMAND" == */* ]]; then
  [[ -x "$CHOWN_COMMAND" ]] || install_common_die "chown command is not executable: $CHOWN_COMMAND"
else
  command -v "$CHOWN_COMMAND" >/dev/null 2>&1 || install_common_die "chown command not found: $CHOWN_COMMAND"
fi

if [[ "$ACTION" == 'deactivate' ]]; then
  if [[ "$CURRENT" == 'baseline' && ! -e "$STATE_FILE" && ! -e "$GUARD_PATH" ]]; then
    printf '[PASS] session handoff is already absent; no files changed.\n'
    exit 0
  fi
  install -m 0644 "$MINIMAL_CONFIG" "$CONFIG_TARGET" || install_common_fail 'unable to restore the minimal Hyprland configuration'
  "$CHOWN_COMMAND" "$TARGET_UID:$TARGET_GID" "$CONFIG_TARGET" || install_common_fail 'unable to restore Hyprland configuration ownership'
  # Only remove a guard this transaction recognises. Every other write here is
  # byte-verified, and an unrecognised binary at that path belongs to whoever
  # put it there.
  if [[ -e "$GUARD_PATH" || -L "$GUARD_PATH" ]]; then
    guard_installed_exactly || install_common_die "refusing to remove an unrecognised file at $GUARD_TARGET"
    rm -f -- "$GUARD_PATH" || install_common_fail 'unable to remove the session guard'
  fi
  rm -f -- "$STATE_FILE" || install_common_fail 'unable to remove the session handoff state'
  set_shell_activation no || install_common_fail 'unable to clear session_activated in the Omarchy shell selection'
  [[ "$(install_common_sha256 "$CONFIG_TARGET")" == "$EXPECTED_MINIMAL_SHA256" ]] || install_common_fail 'restored configuration does not match the reviewed baseline'
  printf '%s\n' \
    "[PASS] configuration        restored to minimal baseline sha256=$EXPECTED_MINIMAL_SHA256" \
    "[PASS] session guard        removed from $GUARD_TARGET" \
    "[PASS] handoff state        removed" \
    '' \
    'The session is back to the minimal compositor. Nothing launches the Omarchy shell.'
  exit 0
fi

if [[ "$CURRENT" == 'activated-this-mode' ]] && guard_installed_exactly && state_matches_mode; then
  # Byte-identical apart from the activation claim, which is repaired rather
  # than left stale so a reapply cannot silently restore an untruthful state.
  if grep -Fxq 'session_activated=yes' "$SHELL_STATE"; then
    printf '[PASS] existing session handoff is byte-for-byte idempotent; no files changed.\n'
  else
    set_shell_activation yes || install_common_fail 'unable to record session_activated in the Omarchy shell selection'
    printf '[PASS] existing session handoff verified; repaired a stale session_activated claim.\n'
  fi
  exit 0
fi

install -Dm0755 "$GUARD_SOURCE" "$GUARD_PATH" || install_common_fail 'unable to install the session guard'
install -m 0644 "$ACTIVATED_TMP" "$CONFIG_TARGET" || install_common_fail 'unable to install the activated Hyprland configuration'
"$CHOWN_COMMAND" "$TARGET_UID:$TARGET_GID" "$CONFIG_TARGET" || install_common_fail 'unable to set Hyprland configuration ownership'

STATE_TMP="$STATE_DIR/.session-handoff-$TARGET_USER.$$"
{
  printf 'target_user=%s\n' "$TARGET_USER"
  printf 'mode=%s\n' "$MODE"
  printf 'guard_path=%s\n' "$GUARD_TARGET"
  printf 'guard_sha256=%s\n' "$EXPECTED_GUARD_SHA256"
  printf 'baseline_sha256=%s\n' "$EXPECTED_MINIMAL_SHA256"
  printf 'config_sha256=%s\n' "$EXPECTED_ACTIVATED_SHA256"
  printf 'userland_version=%s\n' "$EXPECTED_USERLAND_VERSION"
  printf 'display_manager=no\n'
  printf 'autologin=no\n'
  printf 'uwsm=no\n'
  printf 'systemd_unit=no\n'
  printf 'upstream_autostart=no\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage session handoff state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set session handoff state mode'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish session handoff state'

set_shell_activation yes || install_common_fail 'unable to record session_activated in the Omarchy shell selection'

guard_installed_exactly || install_common_fail 'published session guard does not verify'
state_matches_mode || install_common_fail 'published session handoff state does not verify'
[[ "$(install_common_sha256 "$CONFIG_TARGET")" == "$EXPECTED_ACTIVATED_SHA256" ]] || install_common_fail 'published configuration does not verify'

printf '%s\n' \
  "[PASS] session guard        $GUARD_TARGET sha256=$EXPECTED_GUARD_SHA256" \
  "[PASS] configuration        $TARGET_HOME/.config/hypr/hyprland.lua sha256=$EXPECTED_ACTIVATED_SHA256" \
  "[PASS] handoff state        /var/lib/uconsole-omarchy-arm64/session-handoff-$TARGET_USER" \
  "[PASS] shell selection      session_activated=yes" \
  ''
if [[ "$MODE" == 'manual' ]]; then
  printf '%s\n' \
    'Mode manual: the shell starts only on SUPER + O. Booting still lands in the' \
    'minimal compositor. Validate the shell here before selecting autostart.'
else
  printf '%s\n' \
    'Mode autostart: the shell starts with the session. Recover a wedged session' \
    'with --deactivate, which restores the byte-exact minimal configuration.'
fi
