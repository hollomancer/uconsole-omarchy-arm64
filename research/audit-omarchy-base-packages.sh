#!/usr/bin/env bash

# Recreate the complete Omarchy base-package compatibility matrix from the
# pinned Quattro source, pinned Omarchy PKGBUILDs and frozen ALARM databases.
# This is a read-only audit; --emit writes only to stdout.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve research directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

SOURCE_ARCHIVE=""
PACKAGE_SOURCE_ARCHIVE=""
CORE_DB=""
EXTRA_DB=""
ALARM_DB=""
AUR_DB=""
ACTION=check
POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-base-package-policy.tsv"
EXPECTED_MATRIX="$REPO_ROOT/research/package-audit/omarchy-base-packages.tsv"

SOURCE_COMMIT=d99d4fc6de0bc99d48c9935724fa19d7fb41ae54
SOURCE_SHA=3b60bb6d5694478963c167571457ee266cdba1e7791395a80f2f26074d72d6eb
SOURCE_SIZE=70979927
PACKAGE_SOURCE_COMMIT=40ddd6be195a704c1e4187fc7ecd3f2c8091e37b
PACKAGE_SOURCE_SHA=bca5eb81e4bac833a4a6513b1e16f75dedf9af4d05b4b275812e6912fb92c553
CORE_SHA=e1dc3339e7b9baf3a715509837aff8e73495cfba2d04833ee41525892b3c1b96
EXTRA_SHA=2a587fefde8735bbe6c0c5cb7304a2b666268ec947a33743e30d2c8517684964
ALARM_SHA=783c630bc48aafde125542c3a981379d2cdbc515303e68b3a523bd1a484406f2
AUR_SHA=bdd038c7c32dc6de8977c65659249f3ca4b498c303ded46750eb6ab6f1dad187

usage() {
  printf '%s\n' \
    'Usage: audit-omarchy-base-packages.sh --source-archive FILE' \
    '  --package-source-archive FILE --core-db FILE --extra-db FILE' \
    '  --alarm-db FILE --aur-db FILE [--check|--emit] [options]' \
    '' \
    'Actions:' \
    '  --check            Compare regenerated output with the committed matrix (default)' \
    '  --emit             Print the regenerated matrix to stdout' \
    '' \
    'Options:' \
    '  --policy FILE      Alternate complete package policy' \
    '  --matrix FILE      Alternate expected generated matrix' \
    '  --help             Show this help'
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
    --source-archive) (($# >= 2)) || die '--source-archive requires a path'; SOURCE_ARCHIVE=$2; shift 2 ;;
    --package-source-archive) (($# >= 2)) || die '--package-source-archive requires a path'; PACKAGE_SOURCE_ARCHIVE=$2; shift 2 ;;
    --core-db) (($# >= 2)) || die '--core-db requires a path'; CORE_DB=$2; shift 2 ;;
    --extra-db) (($# >= 2)) || die '--extra-db requires a path'; EXTRA_DB=$2; shift 2 ;;
    --alarm-db) (($# >= 2)) || die '--alarm-db requires a path'; ALARM_DB=$2; shift 2 ;;
    --aur-db) (($# >= 2)) || die '--aur-db requires a path'; AUR_DB=$2; shift 2 ;;
    --policy) (($# >= 2)) || die '--policy requires a path'; POLICY=$2; shift 2 ;;
    --matrix) (($# >= 2)) || die '--matrix requires a path'; EXPECTED_MATRIX=$2; shift 2 ;;
    --check) ACTION=check; shift ;;
    --emit) ACTION=emit; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for input in "$SOURCE_ARCHIVE" "$PACKAGE_SOURCE_ARCHIVE" "$CORE_DB" "$EXTRA_DB" "$ALARM_DB" "$AUR_DB" "$POLICY"; do
  [[ -n "$input" && -f "$input" && ! -L "$input" ]] || die "required input is missing or unsafe: ${input:-unset}"
done
if [[ "$ACTION" == check ]]; then
  [[ -f "$EXPECTED_MATRIX" && ! -L "$EXPECTED_MATRIX" ]] || die "expected matrix is missing or unsafe: $EXPECTED_MATRIX"
fi
for command_name in awk bsdtar cmp comm grep sort; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then stat -c '%s' "$1"
  else stat -f '%z' "$1"
  fi
}

verify_hash() {
  local label=$1
  local input=$2
  local expected=$3
  local observed=""
  observed=$(sha256_file "$input") || die 'neither sha256sum nor shasum is available'
  [[ "$observed" == "$expected" ]] || fail "$label SHA-256 differs: $observed"
}

verify_hash 'Omarchy source archive' "$SOURCE_ARCHIVE" "$SOURCE_SHA"
[[ $(file_size "$SOURCE_ARCHIVE") == "$SOURCE_SIZE" ]] || fail 'Omarchy source archive size differs'
verify_hash 'Omarchy package-source archive' "$PACKAGE_SOURCE_ARCHIVE" "$PACKAGE_SOURCE_SHA"
verify_hash 'core database' "$CORE_DB" "$CORE_SHA"
verify_hash 'extra database' "$EXTRA_DB" "$EXTRA_SHA"
verify_hash 'alarm database' "$ALARM_DB" "$ALARM_SHA"
verify_hash 'aur database' "$AUR_DB" "$AUR_SHA"

AUDIT_TMP_BASE=${TMPDIR:-/tmp}
AUDIT_TMP_BASE=${AUDIT_TMP_BASE%/}
AUDIT_TMP=$(mktemp -d "$AUDIT_TMP_BASE/uconsole-omarchy-package-audit.XXXXXX") || die 'unable to create audit workspace'
cleanup() {
  case "$AUDIT_TMP" in
    /tmp/uconsole-omarchy-package-audit.*|/private/tmp/uconsole-omarchy-package-audit.*|/var/folders/*/T/uconsole-omarchy-package-audit.*|/private/var/folders/*/T/uconsole-omarchy-package-audit.*)
      rm -rf -- "$AUDIT_TMP"
      ;;
    *) printf 'Refusing unsafe audit cleanup path: %s\n' "$AUDIT_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

SOURCE_ROOT="omarchy-$SOURCE_COMMIT"
PACKAGE_SOURCE_ROOT="omarchy-pkgs-$PACKAGE_SOURCE_COMMIT"
UPSTREAM_PACKAGES="$AUDIT_TMP/upstream-packages"
POLICY_PACKAGES="$AUDIT_TMP/policy-packages"
GENERATED_MATRIX="$AUDIT_TMP/omarchy-base-packages.tsv"

if ! bsdtar -xOf "$SOURCE_ARCHIVE" "$SOURCE_ROOT/install/omarchy-base.packages" |
  awk 'NF && $1 !~ /^#/ { if (NF != 1 || $1 !~ /^[a-z0-9@._+-]+$/) exit 1; print $1 }' |
  LC_ALL=C sort -u > "$UPSTREAM_PACKAGES"; then
  fail 'unable to extract a safe upstream package list'
fi
[[ $(awk 'END {print NR}' "$UPSTREAM_PACKAGES") -eq 148 ]] || fail 'upstream base package count differs from 148'

if ! awk -F '|' '
  $0 !~ /^#/ {
    if (NF != 10 || $1 !~ /^[a-z0-9@._+-]+$/ || seen[$1]++) exit 1
    if ($2 !~ /^(desktop-core|visual-configuration|shell-tooling|system-package|development-tool|optional-application|update-infrastructure|omarchy-specific)$/) exit 1
    if ($3 !~ /^(core|phase1-owned|conditional|development|optional|deferred|omit|off-target)$/) exit 1
    if ($4 !~ /^(archlinuxarm|replacement|source-build|local-build|defer|omit)$/) exit 1
    if ($5 == "" || $6 == "" || $7 == "" || $8 == "" || $9 == "" || $10 == "") exit 1
    if ($3 == "core" && $4 ~ /^(defer|omit)$/) exit 1
    if ($4 == "archlinuxarm" && $1 != $5) exit 1
    if ($4 == "replacement" && $1 == $5) exit 1
    if ($4 ~ /^(archlinuxarm|replacement)$/ && ($6 !~ /^(core|extra|alarm|aur)$/ || $7 != "snapshot" || $8 != "snapshot")) exit 1
    if ($4 !~ /^(archlinuxarm|replacement)$/ && ($7 == "snapshot" || $8 == "snapshot")) exit 1
    print $1
  }
' "$POLICY" | LC_ALL=C sort > "$POLICY_PACKAGES"; then
  fail 'package policy has invalid fields, duplicates or unsafe dispositions'
fi
[[ $(awk 'END {print NR}' "$POLICY_PACKAGES") -eq 148 ]] || fail 'package policy count differs from 148'
if ! cmp -s "$UPSTREAM_PACKAGES" "$POLICY_PACKAGES"; then
  comm -3 "$UPSTREAM_PACKAGES" "$POLICY_PACKAGES" >&2
  fail 'package policy does not exactly cover the pinned upstream base list'
fi

mkdir -p "$AUDIT_TMP/db/core" "$AUDIT_TMP/db/extra" "$AUDIT_TMP/db/alarm" "$AUDIT_TMP/db/aur" || die 'unable to create database workspace'
for repository in core extra alarm aur; do
  case "$repository" in
    core) database=$CORE_DB ;;
    extra) database=$EXTRA_DB ;;
    alarm) database=$ALARM_DB ;;
    aur) database=$AUR_DB ;;
  esac
  bsdtar -xf "$database" -C "$AUDIT_TMP/db/$repository" || fail "unable to extract frozen $repository database"
done

shopt -s nullglob
repository_lookup() {
  local wanted_name=$1
  local wanted_repository=$2
  local description=""
  local metadata=""
  local observed_name=""
  local observed_version=""
  local observed_architecture=""
  local count=0
  local result=""

  for description in "$AUDIT_TMP/db/$wanted_repository"/"$wanted_name"-*/desc; do
    metadata=$(awk '
      /^%NAME%$/ {getline; name=$0}
      /^%VERSION%$/ {getline; version=$0}
      /^%ARCH%$/ {getline; architecture=$0}
      END {printf "%s|%s|%s\n", name, version, architecture}
    ' "$description") || return 1
    IFS='|' read -r observed_name observed_version observed_architecture <<< "$metadata"
    [[ "$observed_name" == "$wanted_name" ]] || continue
    [[ -n "$observed_version" && ( "$observed_architecture" == aarch64 || "$observed_architecture" == any ) ]] || return 1
    result="$observed_name|$wanted_repository|$observed_version|$observed_architecture"
    count=$((count + 1))
  done
  [[ $count -eq 1 ]] || return 1
  printf '%s\n' "$result"
}

EXACT_MATCHES=0
while IFS= read -r upstream_name; do
  for repository in core extra alarm aur; do
    if repository_lookup "$upstream_name" "$repository" >/dev/null; then
      EXACT_MATCHES=$((EXACT_MATCHES + 1))
      break
    fi
  done
done < "$UPSTREAM_PACKAGES"
[[ $EXACT_MATCHES -eq 121 ]] || fail "frozen exact-name result differs: $EXACT_MATCHES of 148"

printf '# package|category|required_group|resolution|resolved_name|source|version|architecture|runtime_gate|functional_difference\n' > "$GENERATED_MATRIX" || fail 'unable to create generated matrix'
while IFS='|' read -r package category required_group resolution resolved_name source version architecture runtime_gate functional_difference extra; do
  [[ -n "$package" && "$package" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "unexpected policy field for $package"
  if [[ "$resolution" == archlinuxarm || "$resolution" == replacement ]]; then
    repository_row=$(repository_lookup "$resolved_name" "$source") || fail "repository resolution is missing or ambiguous: $package -> $resolved_name ($source)"
    version=$(printf '%s\n' "$repository_row" | awk -F '|' '{print $3}')
    architecture=$(printf '%s\n' "$repository_row" | awk -F '|' '{print $4}')
  elif [[ "$source" == omarchy-pkgs ]]; then
    pkgbuild_entry="$PACKAGE_SOURCE_ROOT/pkgbuilds/$package/PKGBUILD"
    pkgbuild_text=$(bsdtar -xOf "$PACKAGE_SOURCE_ARCHIVE" "$pkgbuild_entry" 2>/dev/null) || fail "pinned Omarchy PKGBUILD is missing: $package"
    arch_line=$(printf '%s\n' "$pkgbuild_text" | awk '/^arch=/ {print; exit}')
    [[ -n "$arch_line" ]] || fail "pinned Omarchy PKGBUILD lacks arch metadata: $package"
    if ! printf '%s\n' "$arch_line" | grep -Eq "(^|[^A-Za-z0-9_])${architecture}([^A-Za-z0-9_]|$)"; then
      fail "declared architecture differs for $package: expected $architecture; observed $arch_line"
    fi
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$package" "$category" "$required_group" "$resolution" "$resolved_name" \
    "$source" "$version" "$architecture" "$runtime_gate" "$functional_difference" >> "$GENERATED_MATRIX" || fail 'unable to append generated matrix'
done < "$POLICY"

GENERATED_ROWS=$(awk '$0 !~ /^#/ {count++} END {print count+0}' "$GENERATED_MATRIX")
[[ $GENERATED_ROWS -eq 148 ]] || fail 'generated matrix row count differs'
if [[ "$ACTION" == emit ]]; then
  cat "$GENERATED_MATRIX"
else
  cmp -s "$GENERATED_MATRIX" "$EXPECTED_MATRIX" || fail 'committed package matrix differs from regenerated evidence'
fi

printf '[PASS] package matrix        upstream=148 exact-name=121 classified=148 unknown=0\n' >&2
printf '[PASS] evidence pins         Omarchy source, package source and four ALARM databases\n' >&2
printf '[PASS] architecture policy   repository metadata and pinned PKGBUILD declarations agree\n' >&2
