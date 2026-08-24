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

POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-base-package-policy.tsv"
MATRIX="$REPO_ROOT/research/package-audit/omarchy-base-packages.tsv"

for input in "$POLICY" "$MATRIX"; do
  [[ -f "$input" && ! -L "$input" ]] || { printf 'Missing or unsafe package audit file: %s\n' "$input" >&2; exit 1; }
done

POLICY_ROWS=$(awk '$0 !~ /^#/ {count++} END {print count+0}' "$POLICY")
MATRIX_ROWS=$(awk '$0 !~ /^#/ {count++} END {print count+0}' "$MATRIX")
[[ $POLICY_ROWS -eq 148 && $MATRIX_ROWS -eq 148 ]] || { printf 'Expected 148 policy and matrix rows\n' >&2; exit 1; }

if ! awk -F '|' '
  NR == FNR && $0 !~ /^#/ { policy[$1]=$0; next }
  $0 !~ /^#/ {
    if (NF != 10 || !($1 in policy) || seen[$1]++) exit 1
    split(policy[$1], expected, "|")
    for (field=1; field<=10; field++) {
      if ((field == 7 || field == 8) && expected[field] == "snapshot") {
        if ($field == "" || $field == "snapshot") exit 1
      } else if ($field != expected[field]) exit 1
    }
    if ($4 ~ /^(archlinuxarm|replacement)$/ && $8 !~ /^(aarch64|any)$/) exit 1
    if ($3 == "core" && $4 ~ /^(defer|omit)$/) exit 1
    count++
  }
  END {if (count != 148) exit 1}
' "$POLICY" "$MATRIX"; then
  printf 'Generated package matrix does not agree with the complete policy\n' >&2
  exit 1
fi

RESOLUTION_COUNTS=$(awk -F '|' '$0 !~ /^#/ {count[$4]++} END {
  printf "archlinuxarm=%d replacement=%d local-build=%d source-build=%d defer=%d omit=%d", \
    count["archlinuxarm"], count["replacement"], count["local-build"], \
    count["source-build"], count["defer"], count["omit"]
}' "$MATRIX")
EXPECTED_COUNTS='archlinuxarm=121 replacement=2 local-build=6 source-build=9 defer=5 omit=5'
[[ "$RESOLUTION_COUNTS" == "$EXPECTED_COUNTS" ]] || { printf 'Unexpected resolution counts: %s\n' "$RESOLUTION_COUNTS" >&2; exit 1; }

UNKNOWN_RESOLUTIONS=$(awk -F '|' '$0 !~ /^#/ && $4 !~ /^(archlinuxarm|replacement|local-build|source-build|defer|omit)$/ {count++} END {print count+0}' "$MATRIX")
[[ $UNKNOWN_RESOLUTIONS -eq 0 ]] || { printf 'Unclassified package resolution remains\n' >&2; exit 1; }

printf 'Omarchy package policy tests: PASS (%s)\n' "$RESOLUTION_COUNTS"
