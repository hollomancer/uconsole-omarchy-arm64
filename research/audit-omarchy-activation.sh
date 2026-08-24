#!/usr/bin/env bash

# Verify that the pinned Omarchy source still matches the reviewed ARM shell
# plugin and command boundary. This is a lexical, fail-closed activation audit;
# it does not start Quickshell or change the host.

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

SOURCE_ARCHIVE=""
SOURCE_LOCK="$REPO_ROOT/config/arm64-overrides/omarchy-source.lock"
PLUGIN_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-plugin-policy.tsv"
COMMAND_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-command-policy.tsv"
COMMAND_OVERRIDES="$REPO_ROOT/packaging/omarchy-arm64-userland/overrides"
SHELL_CONFIG="$REPO_ROOT/config/arm64-overrides/shell.json"
MENU_CONFIG="$REPO_ROOT/config/arm64-overrides/omarchy-menu.jsonc"
EXPECTED_PLUGIN_COUNT=37
EXPECTED_PLUGIN_SHA256='47c2c3d67e4dea367147124badd47e603a9b6a35004b1b4a91b751f9bba9bc56'
EXPECTED_COMMAND_COUNT=432
EXPECTED_COMMAND_SHA256='ade2db01589567a730cd1b7018712a6bf11c43f45e8e3889143305a908c0d777'
EXPECTED_REFERENCE_COUNT=141
EXPECTED_REFERENCE_SHA256='e89ab7b0bba5ea9c77d2ec14185841549f885925557bffb88bcd53c6162c2d69'

usage() {
  printf 'Usage: audit-omarchy-activation.sh --source-archive FILE [--source-lock FILE]\n'
}

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

while (($# > 0)); do
  case "$1" in
    --source-archive) (($# >= 2)) || die '--source-archive requires a file'; SOURCE_ARCHIVE=$2; shift 2 ;;
    --source-lock) (($# >= 2)) || die '--source-lock requires a file'; SOURCE_LOCK=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$SOURCE_ARCHIVE" ]] || die 'source archive is required and must exist'
for required in "$SOURCE_LOCK" "$PLUGIN_POLICY" "$COMMAND_POLICY" "$SHELL_CONFIG" "$MENU_CONFIG"; do
  [[ -f "$required" ]] || die "required policy input is missing: $required"
done
for command in bsdtar jq rg; do command -v "$command" >/dev/null 2>&1 || die "$command is required"; done

source_field() {
  local index=$1
  awk -F '|' -v field="$index" '$0 !~ /^#/ && $1 == "omarchy" { count++; value=$field } END { if (count == 1 && value != "") print value; else exit 1 }' "$SOURCE_LOCK"
}
SOURCE_COMMIT=$(source_field 3) || die 'invalid source commit lock'
SOURCE_SHA256=$(source_field 4) || die 'invalid source digest lock'
SOURCE_ROOT=$(source_field 5) || die 'invalid source root lock'
[[ "$(sha256_file "$SOURCE_ARCHIVE")" == "$SOURCE_SHA256" ]] || die 'source archive digest does not match lock'

AUDIT_BASE=${TMPDIR:-/tmp}
AUDIT_BASE=${AUDIT_BASE%/}
AUDIT_TMP=$(mktemp -d "$AUDIT_BASE/uconsole-omarchy-activation-audit.XXXXXX") || die 'unable to create temporary directory'
cleanup() {
  case "$AUDIT_TMP" in
    /tmp/uconsole-omarchy-activation-audit.*|/private/tmp/uconsole-omarchy-activation-audit.*|/var/folders/*/T/uconsole-omarchy-activation-audit.*|/private/var/folders/*/T/uconsole-omarchy-activation-audit.*) rm -rf -- "$AUDIT_TMP" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$AUDIT_TMP" >&2 ;;
  esac
}
trap cleanup EXIT
bsdtar -xf "$SOURCE_ARCHIVE" -C "$AUDIT_TMP" || die 'unable to extract source archive'
SOURCE_DIR="$AUDIT_TMP/$SOURCE_ROOT"
[[ -d "$SOURCE_DIR" ]] || die 'locked source root is absent after extraction'
[[ "$SOURCE_ROOT" == "omarchy-$SOURCE_COMMIT" ]] || die 'source root and commit do not agree'

PLUGIN_INVENTORY="$AUDIT_TMP/plugins.tsv"
find "$SOURCE_DIR/shell/plugins" \( -name manifest.json -o -name '*.manifest.json' \) -print0 |
  xargs -0 jq -r '[.id,(.kinds|sort|join(",")),(.entryPoints|to_entries|sort_by(.key)|map(.key+"="+.value)|join(","))]|@tsv' |
  LC_ALL=C sort > "$PLUGIN_INVENTORY" || die 'unable to build plugin inventory'
[[ "$(wc -l < "$PLUGIN_INVENTORY" | tr -d ' ')" == "$EXPECTED_PLUGIN_COUNT" ]] || die 'plugin inventory count changed'
[[ "$(sha256_file "$PLUGIN_INVENTORY")" == "$EXPECTED_PLUGIN_SHA256" ]] || die 'plugin inventory changed; review upstream manifests before activation'

POLICY_IDS="$AUDIT_TMP/plugin-policy-ids"
awk -F '|' '$0 !~ /^#/ && NF { if ($3 != "enable" && $3 != "disable") exit 2; print $1 "\t" $2 }' "$PLUGIN_POLICY" |
  LC_ALL=C sort > "$POLICY_IDS" || die 'plugin policy contains an invalid disposition'
cut -f1,2 "$PLUGIN_INVENTORY" > "$AUDIT_TMP/plugin-inventory-ids"
cmp -s "$POLICY_IDS" "$AUDIT_TMP/plugin-inventory-ids" || die 'plugin policy does not cover the exact manifest inventory'

jq -e . "$SHELL_CONFIG" >/dev/null || die 'ARM shell configuration is not valid JSON'
jq -e . "$MENU_CONFIG" >/dev/null || die 'ARM menu configuration is not valid JSONC-compatible JSON'
awk -F '|' '$0 !~ /^#/ && $3 == "disable" { print $1 }' "$PLUGIN_POLICY" | LC_ALL=C sort > "$AUDIT_TMP/policy-disabled"
jq -r '.disabledPlugins[]' "$SHELL_CONFIG" | LC_ALL=C sort > "$AUDIT_TMP/config-disabled"
cmp -s "$AUDIT_TMP/policy-disabled" "$AUDIT_TMP/config-disabled" || die 'shell disabledPlugins does not exactly match plugin policy'

jq -r '.bar.layout | [.left[],.center[],.right[]] | .[].id' "$SHELL_CONFIG" | LC_ALL=C sort -u > "$AUDIT_TMP/layout-ids"
while IFS= read -r plugin_id; do
  awk -F '|' -v wanted="$plugin_id" '$0 !~ /^#/ && $1 == wanted && $3 == "enable" { found=1 } END { exit !found }' "$PLUGIN_POLICY" ||
    die "bar layout references a plugin that is not enabled: $plugin_id"
done < "$AUDIT_TMP/layout-ids"

COMMAND_INVENTORY="$AUDIT_TMP/commands.txt"
find "$SOURCE_DIR/bin" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort > "$COMMAND_INVENTORY"
[[ "$(wc -l < "$COMMAND_INVENTORY" | tr -d ' ')" == "$EXPECTED_COMMAND_COUNT" ]] || die 'command inventory count changed'
[[ "$(sha256_file "$COMMAND_INVENTORY")" == "$EXPECTED_COMMAND_SHA256" ]] || die 'command inventory changed; default-deny review is required'

awk -F '|' '$0 !~ /^#/ && NF { if ($2 != "internal" && $2 != "expose") exit 2; print $1 }' "$COMMAND_POLICY" |
  LC_ALL=C sort > "$AUDIT_TMP/selected-commands" || die 'command policy contains an invalid visibility'
[[ "$(uniq -d "$AUDIT_TMP/selected-commands" | wc -l | tr -d ' ')" == 0 ]] || die 'command policy contains duplicate commands'
[[ "$(wc -l < "$AUDIT_TMP/selected-commands" | tr -d ' ')" == 37 ]] || die 'selected command count changed'
comm -23 "$AUDIT_TMP/selected-commands" "$COMMAND_INVENTORY" > "$AUDIT_TMP/missing-commands"
[[ ! -s "$AUDIT_TMP/missing-commands" ]] || die "policy selects commands absent from source: $(tr '\n' ' ' < "$AUDIT_TMP/missing-commands")"

# Follow calls made by the actual packaged implementation. Eight broad
# upstream actions are replaced by explicit fail-closed first-run commands;
# everything else comes byte-for-byte from the pinned source.
EXPECTED_OVERRIDE_NAMES="$AUDIT_TMP/expected-overrides"
printf '%s\n' \
  omarchy-audio-tuning \
  omarchy-dns \
  omarchy-launch-floating-terminal-with-presentation \
  omarchy-remove-launcher-entry \
  omarchy-theme-bg-set \
  omarchy-theme-bg-switcher \
  omarchy-theme-set \
  omarchy-theme-switcher \
  > "$EXPECTED_OVERRIDE_NAMES"
find "$COMMAND_OVERRIDES" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort > "$AUDIT_TMP/observed-overrides"
cmp -s "$EXPECTED_OVERRIDE_NAMES" "$AUDIT_TMP/observed-overrides" || die 'ARM command override inventory changed'

IMPLEMENTATION_REFS="$AUDIT_TMP/implementation-references"
: > "$IMPLEMENTATION_REFS"
while IFS= read -r command_name; do
  implementation="$SOURCE_DIR/bin/$command_name"
  if grep -Fxq "$command_name" "$EXPECTED_OVERRIDE_NAMES"; then implementation="$COMMAND_OVERRIDES/$command_name"; fi
  [[ -f "$implementation" && ! -L "$implementation" ]] || die "selected command implementation is missing or unsafe: $command_name"
  bash -n "$implementation" || die "selected command has invalid shell syntax: $command_name"
  if sed '/^[[:space:]]*#/d' "$implementation" | rg '(^|[;&|[:space:]])(source|\.)[[:space:]]' >/dev/null; then
    die "selected command sources unbundled shell code: $command_name"
  fi
  sed '/^[[:space:]]*#/d' "$implementation" | rg -o 'omarchy-[a-z0-9-]+' >> "$IMPLEMENTATION_REFS"
done < "$AUDIT_TMP/selected-commands"
LC_ALL=C sort -u "$IMPLEMENTATION_REFS" -o "$IMPLEMENTATION_REFS"
comm -12 "$IMPLEMENTATION_REFS" "$COMMAND_INVENTORY" > "$AUDIT_TMP/implementation-command-references"
comm -23 "$AUDIT_TMP/implementation-command-references" "$AUDIT_TMP/selected-commands" > "$AUDIT_TMP/unselected-transitive-commands"
[[ ! -s "$AUDIT_TMP/unselected-transitive-commands" ]] || die "selected implementation reaches a blocked command: $(tr '\n' ' ' < "$AUDIT_TMP/unselected-transitive-commands")"

REFERENCES="$AUDIT_TMP/references.txt"
rg -o --no-filename --glob '!emojis.json' 'omarchy-[a-z0-9-]+' "$SOURCE_DIR/shell" "$SOURCE_DIR/config/hypr" "$SOURCE_DIR/default/hypr" |
  LC_ALL=C sort -u > "$REFERENCES" || die 'unable to scan shell and Hyprland command references'
[[ "$(wc -l < "$REFERENCES" | tr -d ' ')" == "$EXPECTED_REFERENCE_COUNT" ]] || die 'shell/Hyprland reference count changed'
[[ "$(sha256_file "$REFERENCES")" == "$EXPECTED_REFERENCE_SHA256" ]] || die 'shell/Hyprland references changed; review is required'

# The reduced menu may invoke only exposed Omarchy commands. It deliberately
# contains no updater, package-manager, boot, firmware, kernel or initramfs path.
rg -o --no-filename 'omarchy-[a-z0-9-]+' "$MENU_CONFIG" | LC_ALL=C sort -u > "$AUDIT_TMP/menu-commands"
awk -F '|' '$0 !~ /^#/ && $2 == "expose" { print $1 }' "$COMMAND_POLICY" | LC_ALL=C sort > "$AUDIT_TMP/exposed-commands"
comm -23 "$AUDIT_TMP/menu-commands" "$AUDIT_TMP/exposed-commands" > "$AUDIT_TMP/unsafe-menu-commands"
[[ ! -s "$AUDIT_TMP/unsafe-menu-commands" ]] || die 'reduced menu invokes a command not exposed by policy'

if rg -n '(omarchy-update|omarchy-pkg-|pacman|limine|mkinitcpio|rpi-eeprom|/boot)' "$MENU_CONFIG" "$SHELL_CONFIG" >/dev/null; then
  die 'ARM activation configuration contains a forbidden update, package or boot path'
fi
if awk -F '|' '$0 !~ /^#/ && $2 == "expose" && $1 ~ /(update|migrate|pkg|boot|kernel|firmware|snapper|limine)/ { found=1 } END { exit !found }' "$COMMAND_POLICY"; then
  die 'a hardware or update ownership command is exposed'
fi

ENABLED_COUNT=$(awk -F '|' '$0 !~ /^#/ && $3 == "enable" {n++} END {print n+0}' "$PLUGIN_POLICY") || die 'unable to count enabled plugins'
DISABLED_COUNT=$(awk -F '|' '$0 !~ /^#/ && $3 == "disable" {n++} END {print n+0}' "$PLUGIN_POLICY") || die 'unable to count disabled plugins'
EXPOSED_COUNT=$(awk -F '|' '$0 !~ /^#/ && $2 == "expose" {n++} END {print n+0}' "$COMMAND_POLICY") || die 'unable to count exposed commands'
INTERNAL_COUNT=$(awk -F '|' '$0 !~ /^#/ && $2 == "internal" {n++} END {print n+0}' "$COMMAND_POLICY") || die 'unable to count internal commands'

printf '%s\n' \
  "PASS source             commit=$SOURCE_COMMIT sha256=$SOURCE_SHA256" \
  "PASS plugin inventory   count=$EXPECTED_PLUGIN_COUNT sha256=$EXPECTED_PLUGIN_SHA256" \
  "PASS plugin policy      enabled=$ENABLED_COUNT disabled=$DISABLED_COUNT" \
  "PASS command inventory  count=$EXPECTED_COMMAND_COUNT sha256=$EXPECTED_COMMAND_SHA256 default=blocked" \
  "PASS command policy     exposed=$EXPOSED_COUNT internal=$INTERNAL_COUNT" \
  "PASS command closure    shipped-references=$(wc -l < "$AUDIT_TMP/implementation-command-references" | tr -d ' ') unselected=0 sourced-libraries=0 overrides=8" \
  "PASS reference lock     count=$EXPECTED_REFERENCE_COUNT sha256=$EXPECTED_REFERENCE_SHA256" \
  'PASS ownership boundary no update, package, boot, firmware, kernel or initramfs command is exposed'
