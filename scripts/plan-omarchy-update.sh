#!/usr/bin/env bash

# Audit a prospective Omarchy source update without executing upstream code,
# resolving packages or touching a target root. Candidate changes fail closed
# until package, command and migration policy files are explicitly reviewed.

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

CANDIDATE_ARCHIVE=""
CANDIDATE_COMMIT=""
CANDIDATE_SHA256=""
PACKAGE_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-base-package-policy.tsv"
COMMAND_LOCK="$REPO_ROOT/config/arm64-overrides/omarchy-update-commands.lock"
MIGRATION_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-migration-baseline.lock"

usage() {
  printf '%s\n' \
    'Usage: plan-omarchy-update.sh --candidate-archive FILE --candidate-commit SHA1' \
    '  --candidate-sha256 SHA256 [options]' \
    '' \
    'Options:' \
    '  --package-policy FILE    Alternate complete base-package policy' \
    '  --command-lock FILE      Alternate complete update-command policy' \
    '  --migration-policy FILE  Alternate complete migration policy' \
    '  --help                   Show this help' \
    '' \
    'This command is always read-only. There is no apply or update mode.'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --candidate-archive) (($# >= 2)) || die '--candidate-archive requires a path'; CANDIDATE_ARCHIVE=$2; shift 2 ;;
    --candidate-commit) (($# >= 2)) || die '--candidate-commit requires a value'; CANDIDATE_COMMIT=$2; shift 2 ;;
    --candidate-sha256) (($# >= 2)) || die '--candidate-sha256 requires a value'; CANDIDATE_SHA256=$2; shift 2 ;;
    --package-policy) (($# >= 2)) || die '--package-policy requires a path'; PACKAGE_POLICY=$2; shift 2 ;;
    --command-lock) (($# >= 2)) || die '--command-lock requires a path'; COMMAND_LOCK=$2; shift 2 ;;
    --migration-policy) (($# >= 2)) || die '--migration-policy requires a path'; MIGRATION_POLICY=$2; shift 2 ;;
    --apply|--update|--run-migrations|--root|--device) die "$1 is forbidden; this command only audits a source archive" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die 'candidate commit must be a full lowercase Git SHA-1'
[[ "$CANDIDATE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'candidate SHA-256 must be 64 lowercase hexadecimal characters'
for input in "$CANDIDATE_ARCHIVE" "$PACKAGE_POLICY" "$COMMAND_LOCK" "$MIGRATION_POLICY"; do
  [[ -f "$input" && ! -L "$input" ]] || die "required input is missing or unsafe: $input"
done
for command_name in awk bsdtar cmp comm grep sort; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

OBSERVED_ARCHIVE_SHA=$(sha256_file "$CANDIDATE_ARCHIVE") || die 'neither sha256sum nor shasum is available'
[[ "$OBSERVED_ARCHIVE_SHA" == "$CANDIDATE_SHA256" ]] || fail "candidate archive SHA-256 differs: $OBSERVED_ARCHIVE_SHA"

UPDATE_TMP_BASE=${TMPDIR:-/tmp}
UPDATE_TMP_BASE=${UPDATE_TMP_BASE%/}
UPDATE_TMP=$(mktemp -d "$UPDATE_TMP_BASE/uconsole-omarchy-update-plan.XXXXXX") || die 'unable to create update audit workspace'
cleanup() {
  case "$UPDATE_TMP" in
    /tmp/uconsole-omarchy-update-plan.*|/private/tmp/uconsole-omarchy-update-plan.*|/var/folders/*/T/uconsole-omarchy-update-plan.*|/private/var/folders/*/T/uconsole-omarchy-update-plan.*)
      rm -rf -- "$UPDATE_TMP"
      ;;
    *) printf 'Refusing unsafe update-plan cleanup path: %s\n' "$UPDATE_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

CANDIDATE_ROOT="omarchy-$CANDIDATE_COMMIT"
ARCHIVE_LIST="$UPDATE_TMP/archive-list"
if ! bsdtar -tf "$CANDIDATE_ARCHIVE" > "$ARCHIVE_LIST"; then
  fail 'unable to list candidate source archive'
fi
ARCHIVE_ENTRIES=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || fail 'candidate archive contains an empty entry name'
  case "$entry" in
    "$CANDIDATE_ROOT"|"$CANDIDATE_ROOT"/*) ;;
    *) fail "candidate archive entry escapes its commit root: $entry" ;;
  esac
  case "$entry" in
    /*|*'/../'*|../*|*'/..') fail "unsafe candidate archive entry: $entry" ;;
  esac
  ARCHIVE_ENTRIES=$((ARCHIVE_ENTRIES + 1))
done < "$ARCHIVE_LIST"
[[ $ARCHIVE_ENTRIES -gt 0 ]] || fail 'candidate archive is empty'

archive_has() {
  grep -Fqx "$CANDIDATE_ROOT/$1" "$ARCHIVE_LIST"
}

extract_entry() {
  local relative=$1
  local destination=$2
  archive_has "$relative" || return 1
  bsdtar -xOf "$CANDIDATE_ARCHIVE" "$CANDIDATE_ROOT/$relative" > "$destination"
}

UPSTREAM_PACKAGES="$UPDATE_TMP/upstream-packages"
POLICY_PACKAGES="$UPDATE_TMP/policy-packages"
PACKAGE_LIST_RAW="$UPDATE_TMP/omarchy-base.packages"
extract_entry install/omarchy-base.packages "$PACKAGE_LIST_RAW" || fail 'candidate lacks install/omarchy-base.packages'
if ! awk 'NF && $1 !~ /^#/ {if (NF != 1 || $1 !~ /^[a-z0-9@._+-]+$/) exit 1; print $1}' "$PACKAGE_LIST_RAW" | LC_ALL=C sort -u > "$UPSTREAM_PACKAGES"; then
  fail 'candidate base package list is unsafe'
fi
if ! awk -F '|' '$0 !~ /^#/ {if (NF != 10 || $1 !~ /^[a-z0-9@._+-]+$/ || seen[$1]++) exit 1; print $1}' "$PACKAGE_POLICY" | LC_ALL=C sort > "$POLICY_PACKAGES"; then
  fail 'package policy is invalid or has duplicate names'
fi
if ! cmp -s "$UPSTREAM_PACKAGES" "$POLICY_PACKAGES"; then
  printf 'Unreviewed package changes:\n' >&2
  comm -3 "$UPSTREAM_PACKAGES" "$POLICY_PACKAGES" >&2
  fail 'candidate base packages do not exactly match the reviewed ARM policy'
fi
PACKAGE_COUNT=$(awk 'END {print NR}' "$UPSTREAM_PACKAGES")

if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 4 || $1 !~ /^bin\/[a-z0-9@._+-]+$/ || $2 !~ /^[0-9a-f]{64}$/ || seen[$1]++) exit 1
    if ($3 !~ /^(allow-userland|replace-arm|blocked-hardware|blocked-packages|defer-optional)$/ || $4 == "") exit 1
    count++
  }
  END {if (count == 0) exit 1}
' "$COMMAND_LOCK"; then
  fail 'update command lock is invalid, empty or duplicated'
fi

LOCKED_COMMANDS="$UPDATE_TMP/locked-commands"
CANDIDATE_UPDATE_COMMANDS="$UPDATE_TMP/candidate-update-commands"
awk -F '|' '$0 !~ /^#/ {print $1}' "$COMMAND_LOCK" | LC_ALL=C sort > "$LOCKED_COMMANDS"
awk -v root="$CANDIDATE_ROOT/" '
  index($0, root "bin/omarchy-update") == 1 {
    relative=substr($0, length(root)+1)
    if (relative !~ /\/$/) print relative
  }
' "$ARCHIVE_LIST" | LC_ALL=C sort -u > "$CANDIDATE_UPDATE_COMMANDS"
if ! awk '$0 ~ /^bin\/omarchy-update/ {print}' "$LOCKED_COMMANDS" | cmp -s - "$CANDIDATE_UPDATE_COMMANDS"; then
  printf 'Unreviewed update command changes:\n' >&2
  comm -3 <(awk '$0 ~ /^bin\/omarchy-update/ {print}' "$LOCKED_COMMANDS") "$CANDIDATE_UPDATE_COMMANDS" >&2
  fail 'candidate update command inventory differs from the reviewed lock'
fi

COMMAND_COUNT=0
ALLOW_COUNT=0
REPLACE_COUNT=0
BLOCKED_COUNT=0
DEFER_COUNT=0
while IFS='|' read -r relative expected_digest disposition reason extra; do
  [[ -n "$relative" && "$relative" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "unexpected command lock field: $relative"
  command_copy="$UPDATE_TMP/command.$COMMAND_COUNT"
  extract_entry "$relative" "$command_copy" || fail "candidate lacks locked update boundary command: $relative"
  observed_digest=$(sha256_file "$command_copy") || fail "unable to hash candidate command: $relative"
  [[ "$observed_digest" == "$expected_digest" ]] || fail "candidate command changed without review: $relative"
  COMMAND_COUNT=$((COMMAND_COUNT + 1))
  case "$disposition" in
    allow-userland) ALLOW_COUNT=$((ALLOW_COUNT + 1)) ;;
    replace-arm) REPLACE_COUNT=$((REPLACE_COUNT + 1)) ;;
    blocked-hardware|blocked-packages) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
    defer-optional) DEFER_COUNT=$((DEFER_COUNT + 1)) ;;
  esac
  : "$reason"
done < "$COMMAND_LOCK"

if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 3 || $1 !~ /^[0-9]+\.sh$/ || $2 !~ /^[0-9a-f]{64}$/ || seen[$1]++) exit 1
    if ($3 !~ /^(baseline-do-not-run|allow-userland|replace-arm|blocked-hardware|blocked-packages|defer-optional)$/) exit 1
    count++
  }
  END {if (count == 0) exit 1}
' "$MIGRATION_POLICY"; then
  fail 'migration policy is invalid, empty or duplicated'
fi

CANDIDATE_MIGRATIONS="$UPDATE_TMP/candidate-migrations"
awk -v prefix="$CANDIDATE_ROOT/migrations/" '
  index($0, prefix) == 1 {
    name=substr($0, length(prefix)+1)
    if (name ~ /^[0-9]+\.sh$/) print name
  }
' "$ARCHIVE_LIST" | LC_ALL=C sort -u > "$CANDIDATE_MIGRATIONS"
MIGRATION_COUNT=0
BASELINE_COUNT=0
while IFS= read -r migration_name; do
  [[ -n "$migration_name" ]] || continue
  migration_row=$(awk -F '|' -v wanted="$migration_name" '$0 !~ /^#/ && $1 == wanted {count++; row=$0} END {if (count == 1) print row; else exit 1}' "$MIGRATION_POLICY") || fail "candidate migration is unclassified: $migration_name"
  expected_digest=$(printf '%s\n' "$migration_row" | awk -F '|' '{print $2}')
  disposition=$(printf '%s\n' "$migration_row" | awk -F '|' '{print $3}')
  migration_copy="$UPDATE_TMP/migration.$MIGRATION_COUNT"
  extract_entry "migrations/$migration_name" "$migration_copy" || fail "unable to extract candidate migration: $migration_name"
  observed_digest=$(sha256_file "$migration_copy") || fail "unable to hash candidate migration: $migration_name"
  [[ "$observed_digest" == "$expected_digest" ]] || fail "candidate migration changed after review: $migration_name"
  MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
  if [[ "$disposition" == baseline-do-not-run ]]; then BASELINE_COUNT=$((BASELINE_COUNT + 1)); fi
done < "$CANDIDATE_MIGRATIONS"

NONBASELINE_MISSING=0
while IFS='|' read -r migration_name _ disposition _; do
  [[ -n "$migration_name" && "$migration_name" != \#* ]] || continue
  [[ "$disposition" != baseline-do-not-run ]] || continue
  if ! grep -Fqx "$migration_name" "$CANDIDATE_MIGRATIONS"; then
    NONBASELINE_MISSING=$((NONBASELINE_MISSING + 1))
  fi
done < "$MIGRATION_POLICY"
[[ $NONBASELINE_MISSING -eq 0 ]] || fail 'migration policy contains a non-baseline entry absent from the candidate'

printf '%s\n' \
  "[PASS] candidate archive      commit=$CANDIDATE_COMMIT entries=$ARCHIVE_ENTRIES sha256=$CANDIDATE_SHA256" \
  "[PASS] base-package policy   packages=$PACKAGE_COUNT; no unclassified name change" \
  "[PASS] update command policy commands=$COMMAND_COUNT allow=$ALLOW_COUNT replace=$REPLACE_COUNT blocked=$BLOCKED_COUNT deferred=$DEFER_COUNT" \
  "[PASS] migration policy      candidate=$MIGRATION_COUNT baseline-not-run=$BASELINE_COUNT" \
  '[PASS] hardware ownership    boot, firmware, kernel, Pacman-mirror and factory-reset paths remain blocked' \
  '' \
  'Update audit passed. No source command, package transaction or migration was executed.' \
  'Promotion still requires an offline image update and byte-for-byte hardware manifest comparison.'
