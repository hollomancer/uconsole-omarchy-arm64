#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RUNNER="$REPO_ROOT/research/archive-project-volume.sh"
INSIDE="$REPO_ROOT/research/container/archive-project-volume-inside.sh"

bash -n "$RUNNER" "$INSIDE"
HELP_OUTPUT=$($RUNNER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq -- '--restore-verify'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'Original volumes are never removed'

for forbidden in --remove-source --delete-volume --publish --device; do
  "$RUNNER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected %s to be rejected\n' "$forbidden" >&2; exit 1; }
done

"$RUNNER" --volume unsafe --archive-directory unsafe >/dev/null 2>&1
[[ $? -eq 2 ]] || { printf 'Expected unsafe archive inputs to be rejected\n' >&2; exit 1; }

grep -Fq 'dst=/source,readonly' "$RUNNER"
grep -Fq 'dst=/archive,readonly' "$RUNNER"
grep -Fq -- '--read-only --log-driver none' "$RUNNER"
grep -Fq 'tar_flags=(--acls --xattrs' "$INSIDE"
grep -Fq 'tar --compare' "$INSIDE"
grep -Fq 'contains_synthetic_credentials' "$INSIDE"
grep -Fq 'docker volume rm "$RESTORE_VOLUME"' "$RUNNER"
! grep -Fq 'docker volume rm "$VOLUME"' "$RUNNER"

printf 'project volume archive contract tests: PASS\n'
