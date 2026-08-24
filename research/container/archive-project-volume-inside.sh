#!/usr/bin/env bash

# Create/compare a metadata-preserving GNU tar archive, or prove restoration
# into an empty disposable volume. This script never removes an original.

set -u
set -o pipefail
umask 077

ACTION=${UCONSOLE_ARCHIVE_ACTION:-}
VOLUME=${UCONSOLE_VOLUME_NAME:-}
[[ "$ACTION" == archive || "$ACTION" == restore ]] || { printf 'FAIL: invalid archive action\n' >&2; exit 1; }
[[ "$VOLUME" =~ ^uconsole-(base-system|hyprland)-integration-[0-9]{8}$ ]] || { printf 'FAIL: invalid project volume name\n' >&2; exit 1; }

ARCHIVE=/archive/${VOLUME}.tar
MANIFEST=/archive/${VOLUME}.archive.json
ARCHIVE_PARTIAL=${ARCHIVE}.partial
MANIFEST_PARTIAL=${MANIFEST}.partial

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local cleanup_status=$?
  trap - EXIT INT TERM
  if [[ -f "$ARCHIVE_PARTIAL" ]]; then rm -f -- "$ARCHIVE_PARTIAL" || cleanup_status=1; fi
  if [[ -f "$MANIFEST_PARTIAL" ]]; then rm -f -- "$MANIFEST_PARTIAL" || cleanup_status=1; fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar_flags=(--acls --xattrs --xattrs-include='*' --numeric-owner --sparse)

if [[ "$ACTION" == archive ]]; then
  [[ -d /source ]] || fail 'read-only source mount is missing'
  [[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" && ! -e "$MANIFEST" && ! -L "$MANIFEST" ]] || fail 'archive outputs already exist'
  [[ ! -e "$ARCHIVE_PARTIAL" && ! -L "$ARCHIVE_PARTIAL" && ! -e "$MANIFEST_PARTIAL" && ! -L "$MANIFEST_PARTIAL" ]] || fail 'partial archive outputs already exist'
  tar --create --file "$ARCHIVE_PARTIAL" "${tar_flags[@]}" --directory /source . || fail 'archive creation failed'
  tar --list --file "$ARCHIVE_PARTIAL" >/dev/null || fail 'archive list/integrity check failed'
  tar --compare --file "$ARCHIVE_PARTIAL" "${tar_flags[@]}" --directory /source || fail 'archive differs from the read-only source'
  ARCHIVE_SHA=$(sha256sum "$ARCHIVE_PARTIAL" | awk '{print $1}') || fail 'unable to hash archive'
  ARCHIVE_BYTES=$(stat -c '%s' "$ARCHIVE_PARTIAL") || fail 'unable to measure archive'
  SOURCE_KIB=$(du -sk /source | awk '{print $1}') || fail 'unable to measure source'
  SOURCE_ENTRIES=$(find /source -xdev -mindepth 1 -printf '.' | wc -c | tr -d ' ') || fail 'unable to count source entries'
  ARCHIVE_ENTRIES=$(tar --list --file "$ARCHIVE_PARTIAL" | wc -l | tr -d ' ') || fail 'unable to count archive entries'
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "volume": "%s",\n' "$VOLUME"
    printf '  "archive": "%s",\n' "${VOLUME}.tar"
    printf '  "archive_bytes": %s,\n' "$ARCHIVE_BYTES"
    printf '  "archive_sha256": "%s",\n' "$ARCHIVE_SHA"
    printf '  "source_kib": %s,\n' "$SOURCE_KIB"
    printf '  "source_entries": %s,\n' "$SOURCE_ENTRIES"
    printf '  "archive_entries": %s,\n' "$ARCHIVE_ENTRIES"
    printf '  "numeric_owner": true,\n'
    printf '  "acls": true,\n'
    printf '  "xattrs": true,\n'
    printf '  "sparse_files": true,\n'
    printf '  "source_mounted_read_only": true,\n'
    printf '  "source_compare": "PASS",\n'
    printf '  "contains_synthetic_credentials": true,\n'
    printf '  "publish": false\n'
    printf '}\n'
  } > "$MANIFEST_PARTIAL" || fail 'unable to write archive manifest'
  chmod 0600 "$ARCHIVE_PARTIAL" "$MANIFEST_PARTIAL" || fail 'unable to set private archive modes'
  mv "$ARCHIVE_PARTIAL" "$ARCHIVE" || fail 'unable to promote archive'
  mv "$MANIFEST_PARTIAL" "$MANIFEST" || fail 'unable to promote archive manifest'
  printf '[PASS] archive            %s sha256=%s bytes=%s\n' "$ARCHIVE" "$ARCHIVE_SHA" "$ARCHIVE_BYTES"
  printf '[PASS] source comparison  entries=%s source_kib=%s metadata/content match\n' "$SOURCE_ENTRIES" "$SOURCE_KIB"
  printf '[WARN] private archive    contains synthetic credentials; never publish\n'
  exit 0
fi

[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" && -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail 'archive or manifest is missing'
[[ -z "$(find /restore -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'disposable restore volume must be empty'
EXPECTED_SHA=$(awk -F ': ' '$1 ~ /^[[:space:]]*"archive_sha256"$/ { value=$2; gsub(/[",]/, "", value); print value }' "$MANIFEST") || fail 'unable to read archive digest'
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || fail 'archive manifest digest is invalid'
OBSERVED_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}') || fail 'unable to hash archive for restore'
[[ "$OBSERVED_SHA" == "$EXPECTED_SHA" ]] || fail 'archive digest differs from manifest'
tar --list --file "$ARCHIVE" >/dev/null || fail 'archive list/integrity check failed during restore'
tar --extract --file "$ARCHIVE" "${tar_flags[@]}" --same-owner --directory /restore || fail 'archive extraction failed'
tar --compare --file "$ARCHIVE" "${tar_flags[@]}" --directory /restore || fail 'restored filesystem differs from archive'
printf '[PASS] restore comparison archive=%s sha256=%s metadata/content match\n' "$ARCHIVE" "$OBSERVED_SHA"
