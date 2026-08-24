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
PLANNER="$REPO_ROOT/scripts/plan-omarchy-update.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-omarchy-update-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-omarchy-update-test.*|/private/tmp/uconsole-omarchy-update-test.*|/var/folders/*/T/uconsole-omarchy-update-test.*|/private/var/folders/*/T/uconsole-omarchy-update-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARCHIVE_ROOT="omarchy-$COMMIT"
SOURCE="$TEST_TMP/source/$ARCHIVE_ROOT"
ARCHIVE="$TEST_TMP/candidate.tar.gz"
PACKAGE_POLICY="$TEST_TMP/package-policy.tsv"
COMMAND_LOCK="$TEST_TMP/update-commands.lock"
MIGRATION_POLICY="$TEST_TMP/migrations.lock"
mkdir -p "$SOURCE/install" "$SOURCE/bin" "$SOURCE/migrations"
printf '%s\n' alpha beta > "$SOURCE/install/omarchy-base.packages"
printf '#!/usr/bin/env bash\nprintf "fixture update\\n"\n' > "$SOURCE/bin/omarchy-update"
printf '#!/usr/bin/env bash\nprintf "fixture migration\\n"\n' > "$SOURCE/migrations/100.sh"

cat > "$PACKAGE_POLICY" <<'POLICY'
# package|category|required_group|resolution|resolved_name|source|version|architecture|runtime_gate|functional_difference
alpha|shell-tooling|core|archlinuxarm|alpha|extra|1-1|any|phase5-core|None
beta|system-package|optional|archlinuxarm|beta|extra|1-1|aarch64|phase5-optional|None
POLICY
printf 'bin/omarchy-update|%s|replace-arm|fixture top-level update\n' "$(sha256_file "$SOURCE/bin/omarchy-update")" > "$COMMAND_LOCK"
printf '100.sh|%s|baseline-do-not-run\n' "$(sha256_file "$SOURCE/migrations/100.sh")" > "$MIGRATION_POLICY"

build_archive() {
  bsdtar -czf "$ARCHIVE" -C "$TEST_TMP/source" "$ARCHIVE_ROOT"
}

run_plan() {
  "$PLANNER" \
    --candidate-archive "$ARCHIVE" \
    --candidate-commit "$COMMIT" \
    --candidate-sha256 "$(sha256_file "$ARCHIVE")" \
    --package-policy "$PACKAGE_POLICY" \
    --command-lock "$COMMAND_LOCK" \
    --migration-policy "$MIGRATION_POLICY"
}

build_archive
PASS_OUTPUT=""
if ! PASS_OUTPUT=$(run_plan); then
  printf '%s\n' "$PASS_OUTPUT" >&2
  printf 'Expected locked update plan to pass\n' >&2
  exit 1
fi
printf '%s\n' "$PASS_OUTPUT" | grep -Fq 'No source command, package transaction or migration was executed.' || {
  printf 'Passing plan did not report its read-only boundary\n' >&2
  exit 1
}

BAD_SHA_STATUS=0
"$PLANNER" --candidate-archive "$ARCHIVE" --candidate-commit "$COMMIT" \
  --candidate-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --package-policy "$PACKAGE_POLICY" --command-lock "$COMMAND_LOCK" \
  --migration-policy "$MIGRATION_POLICY" >/dev/null 2>&1
BAD_SHA_STATUS=$?
[[ $BAD_SHA_STATUS -eq 1 ]] || { printf 'Expected candidate digest mismatch to fail\n' >&2; exit 1; }

cp "$SOURCE/install/omarchy-base.packages" "$TEST_TMP/base-packages.saved"
printf 'gamma\n' >> "$SOURCE/install/omarchy-base.packages"
build_archive
PACKAGE_STATUS=0
run_plan >/dev/null 2>&1
PACKAGE_STATUS=$?
[[ $PACKAGE_STATUS -eq 1 ]] || { printf 'Expected unclassified package rejection\n' >&2; exit 1; }
cp "$TEST_TMP/base-packages.saved" "$SOURCE/install/omarchy-base.packages"

printf '#!/usr/bin/env bash\n' > "$SOURCE/bin/omarchy-update-new"
build_archive
COMMAND_STATUS=0
run_plan >/dev/null 2>&1
COMMAND_STATUS=$?
[[ $COMMAND_STATUS -eq 1 ]] || { printf 'Expected unclassified update command rejection\n' >&2; exit 1; }
rm "$SOURCE/bin/omarchy-update-new"

printf '#!/usr/bin/env bash\n' > "$SOURCE/migrations/200.sh"
build_archive
MIGRATION_STATUS=0
run_plan >/dev/null 2>&1
MIGRATION_STATUS=$?
[[ $MIGRATION_STATUS -eq 1 ]] || { printf 'Expected unclassified migration rejection\n' >&2; exit 1; }
rm "$SOURCE/migrations/200.sh"

printf 'changed\n' >> "$SOURCE/bin/omarchy-update"
build_archive
CHANGED_COMMAND_STATUS=0
run_plan >/dev/null 2>&1
CHANGED_COMMAND_STATUS=$?
[[ $CHANGED_COMMAND_STATUS -eq 1 ]] || { printf 'Expected changed locked command rejection\n' >&2; exit 1; }

APPLY_STATUS=0
"$PLANNER" --apply >/dev/null 2>&1
APPLY_STATUS=$?
[[ $APPLY_STATUS -eq 2 ]] || { printf 'Expected apply mode rejection\n' >&2; exit 1; }

printf 'Omarchy update-plan tests: PASS\n'
