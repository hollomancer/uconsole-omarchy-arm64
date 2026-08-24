#!/usr/bin/env bash

# Verify and stage a pinned Omarchy userland source tree for ARM64 auditing.
# This deliberately does not activate Omarchy: no commands enter PATH, no home
# is seeded, no services are enabled, and no migration or upstream installer is
# executed. Plan mode is read-only; apply mode only creates the inert source
# tree and selection record in the named offline root.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve script directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION="plan"
ACTION_SET=0
ROOT=""
TARGET_USER=""
SOURCE_ARCHIVE=""
SOURCE_LOCK="$REPO_ROOT/config/arm64-overrides/omarchy-source.lock"
PATH_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-staged-paths.lock"
BLOCK_NOTICE="$REPO_ROOT/config/arm64-overrides/ACTIVATION-BLOCKED.md"
EXPECTED_COMMIT='d99d4fc6de0bc99d48c9935724fa19d7fb41ae54'
EXPECTED_HYPRLAND='0.56.1-3'
EXPECTED_PATHS=(
  LICENSE version bin config shell themes applications
  default/hypr default/themed default/foot
  icon.png icon.txt logo.svg logo.txt
)

usage() {
  printf '%s\n' \
    'Usage: install-omarchy-arm64.sh --root DIR --user NAME --source-archive FILE [--plan|--apply] [options]' \
    '' \
    'Actions:' \
    '  --plan                   Verify inputs and print the inert staging transaction (default)' \
    '  --apply                  Stage pinned source only; do not activate Omarchy' \
    '' \
    'Options:' \
    '  --source-lock FILE       Alternate complete source lock (version bumps/tests)' \
    '  --path-policy FILE       Alternate complete staging allowlist (tests)' \
    '  --help                   Show this help' \
    '' \
    'There is intentionally no --activate option. This script never changes' \
    '/boot, Pacman configuration, initramfs, services, /usr/bin or user files.'
}

set_action() {
  local requested=$1
  if [[ $ACTION_SET -eq 1 && "$ACTION" != "$requested" ]]; then
    install_common_die 'choose exactly one action'
  fi
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --plan) set_action plan; shift ;;
    --apply) set_action apply; shift ;;
    --root)
      (($# >= 2)) || install_common_die '--root requires a directory'
      ROOT=$2
      shift 2
      ;;
    --user)
      (($# >= 2)) || install_common_die '--user requires a name'
      TARGET_USER=$2
      shift 2
      ;;
    --source-archive)
      (($# >= 2)) || install_common_die '--source-archive requires a file'
      SOURCE_ARCHIVE=$2
      shift 2
      ;;
    --source-lock)
      (($# >= 2)) || install_common_die '--source-lock requires a file'
      SOURCE_LOCK=$2
      shift 2
      ;;
    --path-policy)
      (($# >= 2)) || install_common_die '--path-policy requires a file'
      PATH_POLICY=$2
      shift 2
      ;;
    --activate|--run-installer|--run-migrations|--enable-uwsm|--enable-sddm)
      install_common_die "$1 is not implemented; source staging must remain inactive"
      ;;
    --device|--write-device|--allow-live-root)
      install_common_die "$1 is forbidden; this installer accepts an offline filesystem root only"
      ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ -n "$TARGET_USER" ]] || install_common_die '--user is required'
case "$TARGET_USER" in *[!a-zA-Z0-9_-]*|'') install_common_die 'user name contains unsupported characters' ;; esac
[[ -n "$SOURCE_ARCHIVE" ]] || install_common_die '--source-archive is required'
install_common_require_file 'Omarchy source archive' "$SOURCE_ARCHIVE"
install_common_require_file 'Omarchy source lock' "$SOURCE_LOCK"
install_common_require_file 'Omarchy staging path policy' "$PATH_POLICY"
install_common_require_file 'activation block notice' "$BLOCK_NOTICE"
command -v bsdtar >/dev/null 2>&1 || install_common_die 'bsdtar is required to inspect and extract the source archive'

source_field() {
  local index=$1
  awk -F '|' -v field="$index" '$0 !~ /^#/ && $1 == "omarchy" { count++; value=$field } END { if (count == 1 && value != "") print value; else exit 1 }' "$SOURCE_LOCK"
}
SOURCE_VERSION=$(source_field 2) || install_common_die 'invalid Omarchy source version lock'
SOURCE_COMMIT=$(source_field 3) || install_common_die 'invalid Omarchy source commit lock'
SOURCE_SHA256=$(source_field 4) || install_common_die 'invalid Omarchy source digest lock'
SOURCE_ROOT=$(source_field 5) || install_common_die 'invalid Omarchy archive root lock'
SOURCE_SIZE=$(source_field 6) || install_common_die 'invalid Omarchy archive size lock'
[[ "$SOURCE_COMMIT" == "$EXPECTED_COMMIT" ]] || install_common_die 'source lock advances the unaudited Omarchy commit'
[[ ${#SOURCE_SHA256} -eq 64 ]] || install_common_die 'source lock contains a non-SHA256 digest length'
case "$SOURCE_SHA256" in *[!0-9a-f]*) install_common_die 'source lock contains a non-hexadecimal SHA-256' ;; esac
case "$SOURCE_SIZE" in *[!0-9]*|'') install_common_die 'source lock contains a non-numeric archive size' ;; esac
[[ "$SOURCE_ROOT" == "omarchy-$SOURCE_COMMIT" ]] || install_common_die 'archive root does not correspond to the source commit'

OBSERVED_SHA=$(install_common_sha256 "$SOURCE_ARCHIVE") || install_common_die 'unable to hash Omarchy source archive'
[[ "$OBSERVED_SHA" == "$SOURCE_SHA256" ]] || install_common_die "Omarchy source SHA-256 mismatch: $OBSERVED_SHA"
if stat -c '%s' "$SOURCE_ARCHIVE" >/dev/null 2>&1; then
  OBSERVED_SIZE=$(stat -c '%s' "$SOURCE_ARCHIVE")
else
  OBSERVED_SIZE=$(stat -f '%z' "$SOURCE_ARCHIVE") || install_common_die 'unable to read Omarchy archive size'
fi
[[ "$OBSERVED_SIZE" == "$SOURCE_SIZE" ]] || install_common_die "Omarchy source size mismatch: expected $SOURCE_SIZE, observed $OBSERVED_SIZE"

ARCHIVE_LIST=$(bsdtar -tf "$SOURCE_ARCHIVE") || install_common_die 'unable to list Omarchy source archive'
ARCHIVE_COUNT=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || install_common_die 'source archive contains an empty entry name'
  case "$entry" in
    "$SOURCE_ROOT"/*) ;;
    *) install_common_die "source archive entry escapes its locked root: $entry" ;;
  esac
  case "$entry" in
    /*|*'/../'*|../*|*'/..') install_common_die "unsafe source archive entry: $entry" ;;
  esac
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
done <<< "$ARCHIVE_LIST"
[[ $ARCHIVE_COUNT -gt 1000 ]] || install_common_die "source archive is unexpectedly small: $ARCHIVE_COUNT entries"

archive_has() {
  local wanted="$SOURCE_ROOT/$1"
  awk -v file="$wanted" -v directory="$wanted/" '$0 == file || $0 == directory { found=1 } END { exit !found }' <<< "$ARCHIVE_LIST"
}
for path in "${EXPECTED_PATHS[@]}"; do
  archive_has "$path" || install_common_die "source archive lacks required staged path: $path"
done
for sentinel in bin/omarchy-version config/hypr/hyprland.lua config/omarchy/shell.json shell/shell.qml default/hypr/omarchy.lua; do
  archive_has "$sentinel" || install_common_die "source archive lacks required userland sentinel: $sentinel"
done
ARCHIVE_VERSION=$(bsdtar -xOf "$SOURCE_ARCHIVE" "$SOURCE_ROOT/version" 2>/dev/null | tr -d '\r\n') || install_common_die 'unable to read source version sentinel'
[[ "$ARCHIVE_VERSION" == "$SOURCE_VERSION" ]] || install_common_die "source version mismatch: expected $SOURCE_VERSION, observed $ARCHIVE_VERSION"
LICENSE_TEXT=$(bsdtar -xOf "$SOURCE_ARCHIVE" "$SOURCE_ROOT/LICENSE" 2>/dev/null) || install_common_die 'unable to read source license sentinel'
[[ "$LICENSE_TEXT" == *'Permission is hereby granted, free of charge'* ]] || install_common_die 'source license is not the audited MIT text'

POLICY_ROWS=$(awk '$0 !~ /^#/ && NF { count++ } END { print count+0 }' "$PATH_POLICY")
[[ "$POLICY_ROWS" -eq "${#EXPECTED_PATHS[@]}" ]] || install_common_die "staging policy must contain exactly ${#EXPECTED_PATHS[@]} entries"
policy_field() {
  local path=$1
  local index=$2
  awk -F '|' -v wanted="$path" -v field="$index" '$0 !~ /^#/ && $1 == wanted { count++; value=$field } END { if (count == 1 && value != "") print value; else exit 1 }' "$PATH_POLICY"
}
for path in "${EXPECTED_PATHS[@]}"; do
  disposition=$(policy_field "$path" 2) || install_common_die "invalid or duplicate staging policy entry: $path"
  reason=$(policy_field "$path" 3) || install_common_die "missing staging reason: $path"
  case "$disposition" in stage|stage-inactive) ;; *) install_common_die "unsafe staging disposition for $path: $disposition" ;; esac
  [[ -n "$reason" ]] || install_common_die "empty staging reason: $path"
done

ROOT=$(install_common_require_offline_arch_root "$ROOT")
HYPRLAND_STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection"
install_common_require_file 'Hyprland selection state' "$HYPRLAND_STATE"
state_field() {
  local file=$1
  local key=$2
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$file"
}
[[ "$(state_field "$HYPRLAND_STATE" hyprland_version)" == "$EXPECTED_HYPRLAND" ]] || install_common_die 'Hyprland state has an unexpected version'
[[ "$(state_field "$HYPRLAND_STATE" target_user)" == "$TARGET_USER" ]] || install_common_die 'Hyprland state belongs to a different user'
[[ "$(state_field "$HYPRLAND_STATE" uwsm_enabled)" == 'no' ]] || install_common_die 'unexpected UWSM activation before Omarchy audit'

PASSWD_FILE="$ROOT/etc/passwd"
install_common_require_file 'target passwd database' "$PASSWD_FILE"
USER_RECORD=$(awk -F ':' -v wanted="$TARGET_USER" '$1 == wanted { count++; record=$0 } END { if (count == 1) print record; else exit 1 }' "$PASSWD_FILE") || install_common_die "target user is missing or duplicated: $TARGET_USER"
TARGET_HOME=$(printf '%s\n' "$USER_RECORD" | awk -F ':' '{print $6}')
[[ "$TARGET_HOME" == "/home/$TARGET_USER" ]] || install_common_die "target home must be /home/$TARGET_USER"
[[ -d "$ROOT$TARGET_HOME" && ! -L "$ROOT$TARGET_HOME" ]] || install_common_die 'target home is missing or unsafe'

STAGE_PARENT="$ROOT/usr/share/uconsole-omarchy-arm64/upstream"
STAGE_DEST="$STAGE_PARENT/$SOURCE_COMMIT"
STATE_DIR="$ROOT/var/lib/uconsole-omarchy-arm64"
STATE_FILE="$STATE_DIR/omarchy-source-selection"

payload_manifest() {
  local directory=$1
  local relative=""
  local digest=""
  local target=""
  while IFS= read -r relative; do
    relative=${relative#./}
    [[ "$relative" != 'SOURCE-MANIFEST.sha256' ]] || continue
    if [[ -L "$directory/$relative" ]]; then
      target=$(readlink "$directory/$relative") || return 1
      printf 'link  %s -> %s\n' "$relative" "$target"
    elif [[ -f "$directory/$relative" ]]; then
      digest=$(install_common_sha256 "$directory/$relative") || return 1
      printf '%s  %s\n' "$digest" "$relative"
    fi
  done < <(cd -- "$directory" && find . \( -type f -o -type l \) -print | LC_ALL=C sort)
}

if [[ -e "$STAGE_DEST" ]]; then
  [[ -d "$STAGE_DEST" && ! -L "$STAGE_DEST" ]] || install_common_die "unsafe existing source stage: $STAGE_DEST"
  install_common_require_file 'staged source manifest' "$STAGE_DEST/SOURCE-MANIFEST.sha256"
  CURRENT_MANIFEST=$(payload_manifest "$STAGE_DEST") || install_common_die 'unable to verify staged source manifest'
  EXPECTED_MANIFEST=$(<"$STAGE_DEST/SOURCE-MANIFEST.sha256")
  if [[ "$CURRENT_MANIFEST" != "$EXPECTED_MANIFEST" ]]; then
    install_common_die 'existing staged Omarchy source was modified; refusing to overwrite it'
  fi
  install_common_require_file 'Omarchy source selection state' "$STATE_FILE"
  [[ "$(state_field "$STATE_FILE" source_sha256)" == "$SOURCE_SHA256" ]] || install_common_die 'existing source state has a different archive digest'
fi

printf '%s\n' \
  '[PASS] offline root           Arch Linux ARM identity, boot tree and pacman database present' \
  "[PASS] Hyprland gate         $EXPECTED_HYPRLAND staged for $TARGET_USER; UWSM remains disabled" \
  "[PASS] source archive        $SOURCE_VERSION $SOURCE_COMMIT entries=$ARCHIVE_COUNT sha256=$SOURCE_SHA256" \
  "[PASS] staging allowlist     ${#EXPECTED_PATHS[@]} paths; executable tree remains outside PATH" \
  '' \
  "Action: $ACTION" \
  "Root: $ROOT" \
  "Inactive destination: /usr/share/uconsole-omarchy-arm64/upstream/$SOURCE_COMMIT" \
  'Activation: BLOCKED' \
  ''

if [[ "$ACTION" == 'plan' ]]; then
  printf '%s\n' \
    'Plan complete. No package, command, user configuration, service, migration or boot file was changed.' \
    'Apply will stage audit inputs only. It will not make an Omarchy session runnable.'
  exit 0
fi

[[ -w "$ROOT" ]] || install_common_die "offline root is not writable: $ROOT"
if [[ ! -e "$STAGE_DEST" ]]; then
  mkdir -p "$ROOT/var/tmp" "$STAGE_PARENT" || install_common_fail 'unable to create inert staging directories'
  EXTRACT_DIR=$(mktemp -d "$ROOT/var/tmp/omarchy-source.XXXXXX") || install_common_fail 'unable to create source extraction directory'
  cleanup_extract() {
    if [[ -n ${EXTRACT_DIR:-} && -d "$EXTRACT_DIR" ]]; then
      case "$EXTRACT_DIR" in
        "$ROOT/var/tmp/omarchy-source."*) rm -rf -- "$EXTRACT_DIR" ;;
        *) printf 'Refusing unsafe extraction cleanup path: %s\n' "$EXTRACT_DIR" >&2 ;;
      esac
    fi
  }
  trap cleanup_extract EXIT
  if ! bsdtar -xf "$SOURCE_ARCHIVE" -C "$EXTRACT_DIR"; then
    install_common_fail 'unable to extract pinned Omarchy source'
  fi
  EXTRACTED_ROOT="$EXTRACT_DIR/$SOURCE_ROOT"
  [[ -d "$EXTRACTED_ROOT" && ! -L "$EXTRACTED_ROOT" ]] || install_common_fail 'extracted source root is missing or unsafe'
  CANDIDATE="$EXTRACT_DIR/candidate"
  mkdir "$CANDIDATE" || install_common_fail 'unable to create source staging candidate'
  for path in "${EXPECTED_PATHS[@]}"; do
    source_path="$EXTRACTED_ROOT/$path"
    target_path="$CANDIDATE/$path"
    mkdir -p "${target_path%/*}" || install_common_fail "unable to create parent for staged path: $path"
    cp -pR -- "$source_path" "$target_path" || install_common_fail "unable to stage allowed source path: $path"
  done
  install -m 0644 "$BLOCK_NOTICE" "$CANDIDATE/ACTIVATION-BLOCKED.md" || install_common_fail 'unable to stage activation notice'
  payload_manifest "$CANDIDATE" > "$CANDIDATE/SOURCE-MANIFEST.sha256" || install_common_fail 'unable to create staged source manifest'
  mv "$CANDIDATE" "$STAGE_DEST" || install_common_fail 'unable to publish inert Omarchy source tree'
  cleanup_extract
  trap - EXIT
fi

MANIFEST_SHA=$(install_common_sha256 "$STAGE_DEST/SOURCE-MANIFEST.sha256") || install_common_fail 'unable to hash staged source manifest'
STATE_TMP="$STATE_DIR/.omarchy-source-selection.$$"
{
  printf 'source_version=%s\n' "$SOURCE_VERSION"
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'source_sha256=%s\n' "$SOURCE_SHA256"
  printf 'source_manifest_sha256=%s\n' "$MANIFEST_SHA"
  printf 'target_user=%s\n' "$TARGET_USER"
  printf 'activation=blocked\n'
  printf 'commands_exposed=no\n'
  printf 'user_config_seeded=no\n'
  printf 'migrations_initialized=no\n'
} > "$STATE_TMP" || install_common_fail 'unable to stage Omarchy source selection state'
chmod 0644 "$STATE_TMP" || install_common_fail 'unable to set Omarchy source state permissions'
mv "$STATE_TMP" "$STATE_FILE" || install_common_fail 'unable to publish Omarchy source selection state'

[[ ! -e "$ROOT/usr/bin/omarchy" ]] || install_common_fail 'unexpected active Omarchy command appeared during inert staging'
printf '%s\n' \
  "[PASS] inert source tree     /usr/share/uconsole-omarchy-arm64/upstream/$SOURCE_COMMIT" \
  "[PASS] payload manifest      sha256=$MANIFEST_SHA" \
  '[PASS] activation boundary   no command, home seed, service, migration or update path was activated' \
  '[PASS] source state          /var/lib/uconsole-omarchy-arm64/omarchy-source-selection' \
  '' \
  'Pinned Omarchy source staged for audit only. Activation remains blocked.'
