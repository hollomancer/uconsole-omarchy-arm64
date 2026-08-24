#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
BUILDER="$REPO_ROOT/research/build-omarchy-arm64-userland.sh"
SOURCE_ARCHIVE=${OMARCHY_SOURCE_ARCHIVE:-/private/tmp/omarchy-d99d4fc6.tar.gz}

bash -n "$BUILDER" "$REPO_ROOT/research/container/build-omarchy-arm64-userland-inside.sh"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  printf 'omarchy ARM64 userland build tests: SKIP (set OMARCHY_SOURCE_ARCHIVE)\n'
  exit 0
fi

"$BUILDER" --source-archive "$SOURCE_ARCHIVE" --check >/dev/null || {
  printf 'Expected userland build input check to pass\n' >&2
  exit 1
}

for forbidden in --apply --activate --device --root; do
  "$BUILDER" --source-archive "$SOURCE_ARCHIVE" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || { printf 'Expected %s to be rejected\n' "$forbidden" >&2; exit 1; }
done

printf 'omarchy ARM64 userland build tests: PASS\n'
