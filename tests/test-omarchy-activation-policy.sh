#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
AUDITOR="$REPO_ROOT/research/audit-omarchy-activation.sh"
SOURCE_LOCK="$REPO_ROOT/config/arm64-overrides/omarchy-source.lock"
SOURCE_ARCHIVE=${OMARCHY_SOURCE_ARCHIVE:-/private/tmp/omarchy-d99d4fc6.tar.gz}

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  printf 'omarchy activation policy tests: SKIP (set OMARCHY_SOURCE_ARCHIVE to the pinned archive)\n'
  exit 0
fi

"$AUDITOR" --source-archive "$SOURCE_ARCHIVE" --source-lock "$SOURCE_LOCK" >/dev/null || {
  printf 'Expected pinned activation audit to pass\n' >&2
  exit 1
}

if rg -n '\|expose\|.*(update|boot|kernel|firmware|package manager)' "$REPO_ROOT/config/arm64-overrides/omarchy-command-policy.tsv" >/dev/null; then
  printf 'Potentially dangerous command was exposed by policy\n' >&2
  exit 1
fi

printf 'omarchy activation policy tests: PASS\n'
