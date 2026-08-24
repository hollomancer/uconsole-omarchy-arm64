#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
IDENTITY="$REPO_ROOT/config/image/phase1-candidate.env"

[[ -f "$IDENTITY" && ! -L "$IDENTITY" ]]
[[ $(awk 'END { print NR }' "$IDENTITY") -eq 6 ]]

identity_field() {
  local key=$1
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$IDENTITY"
}

[[ $(identity_field schema) == 1 ]]
LINEAGE=$(identity_field lineage)
[[ "$LINEAGE" == 'uconsole-omarchy-arm64:phase1-cm5:2026-08-24' ]]

DISK_HASH=$(printf '%s' "${LINEAGE}:disk" | shasum -a 256 | awk '{ print $1 }')
BOOT_HASH=$(printf '%s' "${LINEAGE}:boot" | shasum -a 256 | awk '{ print $1 }')
ROOT_HASH=$(printf '%s' "${LINEAGE}:root" | shasum -a 256 | awk '{ print $1 }')
[[ $(identity_field disk_id) == "${DISK_HASH:0:8}" ]]
[[ $(identity_field boot_id) == "$(printf '%s' "${BOOT_HASH:0:8}" | tr '[:lower:]' '[:upper:]')" ]]
EXPECTED_ROOT_UUID="${ROOT_HASH:0:8}-${ROOT_HASH:8:4}-4${ROOT_HASH:13:3}-9${ROOT_HASH:17:3}-${ROOT_HASH:20:12}"
[[ $(identity_field root_uuid) == "$EXPECTED_ROOT_UUID" ]]
[[ $(identity_field source_date_epoch) == 1787544000 ]]

printf 'Phase 1 candidate image identity tests: PASS\n'
