#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

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

LICENSE_FILE="$REPO_ROOT/LICENSE"
NOTICES_FILE="$REPO_ROOT/THIRD_PARTY_NOTICES.md"
README_FILE="$REPO_ROOT/README.md"
DKMS_RECIPE="$REPO_ROOT/packaging/uconsole-cm5-dkms/PKGBUILD"
DKMS_NOTICE="$REPO_ROOT/packaging/uconsole-cm5-dkms/PACKAGING-NOTICE"

for REQUIRED_FILE in "$LICENSE_FILE" "$NOTICES_FILE" "$README_FILE" "$DKMS_RECIPE" "$DKMS_NOTICE"; do
  [[ -f "$REQUIRED_FILE" && ! -L "$REQUIRED_FILE" ]] || {
    printf 'Missing or unsafe licensing file: %s\n' "$REQUIRED_FILE" >&2
    exit 1
  }
done

grep -Fxq 'MIT License' "$LICENSE_FILE" || { printf 'Top-level license is not MIT\n' >&2; exit 1; }
grep -Fxq 'Copyright (c) 2026 Conrad Hollomon' "$LICENSE_FILE" || { printf 'MIT copyright holder/year changed unexpectedly\n' >&2; exit 1; }
grep -Fq 'Permission is hereby granted, free of charge' "$LICENSE_FILE" || { printf 'MIT permission grant is incomplete\n' >&2; exit 1; }
grep -Fq 'THE SOFTWARE IS PROVIDED "AS IS"' "$LICENSE_FILE" || { printf 'MIT warranty disclaimer is incomplete\n' >&2; exit 1; }

grep -Fq '[`LICENSE`](LICENSE)' "$NOTICES_FILE" || { printf 'Third-party notice does not define the root-license boundary\n' >&2; exit 1; }
grep -Fq 'bf7a0ab55654c96b74d013520e1196d39f66391a' "$NOTICES_FILE" || { printf 'Third-party notice omits the restricted uConsole source pin\n' >&2; exit 1; }
grep -Fq 'not redistribute the resulting source or binary package' "$NOTICES_FILE" || { printf 'Third-party notice omits the uConsole redistribution restriction\n' >&2; exit 1; }
grep -Fq "custom:unresolved-overlay-glue" "$DKMS_RECIPE" || { printf 'DKMS package no longer declares unresolved licensing\n' >&2; exit 1; }
grep -Fq 'redistribute a built package' "$DKMS_NOTICE" || { printf 'DKMS package notice no longer fails closed\n' >&2; exit 1; }

grep -Fq '[MIT License](LICENSE)' "$README_FILE" || { printf 'README does not link the project license\n' >&2; exit 1; }
grep -Fq '[third-party notices](THIRD_PARTY_NOTICES.md)' "$README_FILE" || { printf 'README does not link third-party notices\n' >&2; exit 1; }

printf 'license boundary contract tests: PASS\n'
