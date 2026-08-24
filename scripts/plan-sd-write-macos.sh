#!/usr/bin/env bash

# Read-only macOS physical-media preflight. The mutable /dev/diskN name is
# accepted only together with exact hardware/media identity fields, and this
# script implements no unmount, erase or write action.

set -u
set -o pipefail

IMAGE=''
MANIFEST=''
DEVICE=''
EXPECTED_MEDIA_NAME=''
EXPECTED_IOREGISTRY_NAME=''
EXPECTED_DEVICE_TREE_PATH=''
EXPECTED_BUS=''
EXPECTED_SIZE=''
PLIST_BUDDY=${UCONSOLE_PLIST_BUDDY:-/usr/libexec/PlistBuddy}
LIST_PLIST_FILE=''

usage() {
  printf '%s\n' \
    'Usage: scripts/plan-sd-write-macos.sh --image FILE.img --manifest FILE.json \' \
    '  --device /dev/diskN --expected-media-name NAME \' \
    '  --expected-ioregistry-name NAME --expected-device-tree-path PATH \' \
    '  --expected-bus BUS --expected-size BYTES' \
    '' \
    'This is a read-only macOS preflight. It requires a removable, external,' \
    'physical whole disk with 512-byte sectors and no mounted descendants.' \
    'APFS targets are rejected because synthesized descendants need a separate audit.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$LIST_PLIST_FILE" && -f "$LIST_PLIST_FILE" ]]; then rm -f -- "$LIST_PLIST_FILE" || status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --image) (($# >= 2)) || die '--image requires a file'; IMAGE=$2; shift 2 ;;
    --manifest) (($# >= 2)) || die '--manifest requires a file'; MANIFEST=$2; shift 2 ;;
    --device) (($# >= 2)) || die '--device requires a whole-disk node'; DEVICE=$2; shift 2 ;;
    --expected-media-name) (($# >= 2)) || die '--expected-media-name requires a value'; EXPECTED_MEDIA_NAME=$2; shift 2 ;;
    --expected-ioregistry-name) (($# >= 2)) || die '--expected-ioregistry-name requires a value'; EXPECTED_IOREGISTRY_NAME=$2; shift 2 ;;
    --expected-device-tree-path) (($# >= 2)) || die '--expected-device-tree-path requires a value'; EXPECTED_DEVICE_TREE_PATH=$2; shift 2 ;;
    --expected-bus) (($# >= 2)) || die '--expected-bus requires a value'; EXPECTED_BUS=$2; shift 2 ;;
    --expected-size) (($# >= 2)) || die '--expected-size requires a byte count'; EXPECTED_SIZE=$2; shift 2 ;;
    --write|--write-device|--unmount|--erase|--format|--i-understand-this-erases-the-device)
      die "$1 is not implemented; this command is read-only"
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || die 'this preflight requires macOS diskutil semantics'
for command_name in diskutil plutil shasum stat awk mktemp mount; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
[[ -x "$PLIST_BUDDY" ]] || die 'PlistBuddy is required for descendant enumeration'
[[ -f "$IMAGE" && ! -L "$IMAGE" && "$IMAGE" == *.img ]] || die 'image must be a regular non-symlink .img file'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die 'manifest must be a regular non-symlink file'
[[ "$DEVICE" =~ ^/dev/disk[0-9]+$ ]] || die 'device must be an exact macOS whole-disk node such as /dev/disk7'
[[ "$EXPECTED_SIZE" =~ ^[0-9]+$ && "$EXPECTED_SIZE" -gt 0 ]] || die 'expected size must be a positive byte count'
for expected_text in "$EXPECTED_MEDIA_NAME" "$EXPECTED_IOREGISTRY_NAME" "$EXPECTED_DEVICE_TREE_PATH" "$EXPECTED_BUS"; do
  [[ -n "$expected_text" && "$expected_text" != *$'\n'* ]] || die 'all expected identity strings are required and must be single-line'
done

manifest_value() {
  local key=$1
  awk -F ': ' -v wanted="\"$key\"" '
    $1 ~ "^[[:space:]]*" wanted "$" {
      count++
      value=$2
      sub(/,$/, "", value)
      gsub(/^"|"$/, "", value)
    }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$MANIFEST"
}

MANIFEST_IMAGE=$(manifest_value image) || die 'manifest lacks exactly one image field'
MANIFEST_SIZE=$(manifest_value image_size) || die 'manifest lacks exactly one image_size field'
MANIFEST_SHA=$(manifest_value image_sha256) || die 'manifest lacks exactly one image_sha256 field'
[[ "$MANIFEST_IMAGE" == "${IMAGE##*/}" ]] || die 'manifest image name differs'
[[ "$MANIFEST_SIZE" =~ ^[0-9]+$ ]] || die 'manifest image_size is invalid'
[[ "$MANIFEST_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'manifest image_sha256 is invalid'
IMAGE_SIZE=$(stat -f '%z' "$IMAGE") || die 'unable to measure image'
[[ "$IMAGE_SIZE" == "$MANIFEST_SIZE" ]] || die "image size differs from manifest: observed=$IMAGE_SIZE expected=$MANIFEST_SIZE"
IMAGE_SHA=$(shasum -a 256 "$IMAGE" | awk '{print $1}') || die 'unable to hash image'
[[ "$IMAGE_SHA" == "$MANIFEST_SHA" ]] || die 'image SHA-256 differs from manifest'

INFO_PLIST=$(diskutil info -plist "$DEVICE") || die 'diskutil could not inspect the target'
plist_value() {
  local key=$1
  printf '%s' "$INFO_PLIST" | plutil -extract "$key" raw -o - -
}
DEVICE_IDENTIFIER=$(plist_value DeviceIdentifier) || die 'target lacks a device identifier'
DEVICE_NODE=$(plist_value DeviceNode) || die 'target lacks a device node'
WHOLE_DISK=$(plist_value WholeDisk) || die 'target lacks whole-disk state'
INTERNAL=$(plist_value Internal) || die 'target lacks internal/external state'
PHYSICAL=$(plist_value VirtualOrPhysical) || die 'target lacks physical state'
REMOVABLE_MEDIA=$(plist_value RemovableMedia) || die 'target lacks removable-media state'
WRITABLE=$(plist_value Writable) || die 'target lacks writable state'
MEDIA_NAME=$(plist_value MediaName) || die 'target lacks media name'
IOREGISTRY_NAME=$(plist_value IORegistryEntryName) || die 'target lacks I/O registry name'
DEVICE_TREE_PATH=$(plist_value DeviceTreePath) || die 'target lacks device-tree path'
BUS=$(plist_value BusProtocol) || die 'target lacks bus protocol'
DEVICE_SIZE=$(plist_value Size) || die 'target lacks byte size'
BLOCK_SIZE=$(plist_value DeviceBlockSize) || die 'target lacks block size'
MOUNT_POINT=$(plist_value MountPoint) || die 'target lacks mount-point state'

[[ "$DEVICE_NODE" == "$DEVICE" && "$DEVICE_IDENTIFIER" == "${DEVICE#/dev/}" ]] || die 'diskutil device identity differs from the requested node'
[[ "$WHOLE_DISK" == true ]] || die 'target is not a whole disk'
[[ "$INTERNAL" == false ]] || die 'target is internal'
[[ "$PHYSICAL" == Physical ]] || die 'target is virtual or synthesized'
[[ "$REMOVABLE_MEDIA" == true ]] || die 'target media is not reported removable'
[[ "$WRITABLE" == true ]] || die 'target is read-only'
[[ "$BLOCK_SIZE" == 512 ]] || die "target sector size is unsupported: $BLOCK_SIZE"
[[ "$MEDIA_NAME" == "$EXPECTED_MEDIA_NAME" ]] || die "media name changed: $MEDIA_NAME"
[[ "$IOREGISTRY_NAME" == "$EXPECTED_IOREGISTRY_NAME" ]] || die "I/O registry name changed: $IOREGISTRY_NAME"
[[ "$DEVICE_TREE_PATH" == "$EXPECTED_DEVICE_TREE_PATH" ]] || die 'device-tree path changed'
[[ "$BUS" == "$EXPECTED_BUS" ]] || die "bus protocol changed: $BUS"
[[ "$DEVICE_SIZE" == "$EXPECTED_SIZE" ]] || die "device size changed: $DEVICE_SIZE"
((DEVICE_SIZE >= IMAGE_SIZE)) || die 'target is smaller than the image'
[[ -z "$MOUNT_POINT" ]] || die "whole-disk node is mounted: $MOUNT_POINT"

LIST_PLIST_FILE=$(mktemp /private/tmp/uconsole-sd-list.XXXXXX) || die 'unable to create private plist workspace'
chmod 0600 "$LIST_PLIST_FILE" || die 'unable to secure plist workspace'
diskutil list -plist "$DEVICE" > "$LIST_PLIST_FILE" || die 'unable to list target descendants'
LIST_WHOLE=$($PLIST_BUDDY -c 'Print :AllDisksAndPartitions:0:DeviceIdentifier' "$LIST_PLIST_FILE" 2>/dev/null) || die 'partition list lacks the requested whole disk'
[[ "$LIST_WHOLE" == "$DEVICE_IDENTIFIER" ]] || die 'partition list belongs to a different whole disk'

PARTITION_COUNT=0
partition_index=0
while ((partition_index < 128)); do
  PARTITION_IDENTIFIER=$("$PLIST_BUDDY" -c "Print :AllDisksAndPartitions:0:Partitions:$partition_index:DeviceIdentifier" "$LIST_PLIST_FILE" 2>/dev/null) || break
  [[ "$PARTITION_IDENTIFIER" =~ ^${DEVICE_IDENTIFIER}s[0-9]+$ ]] || die "unsafe descendant identifier: $PARTITION_IDENTIFIER"
  PARTITION_CONTENT=$("$PLIST_BUDDY" -c "Print :AllDisksAndPartitions:0:Partitions:$partition_index:Content" "$LIST_PLIST_FILE" 2>/dev/null) || die "descendant lacks content type: $PARTITION_IDENTIFIER"
  [[ "$PARTITION_CONTENT" != Apple_APFS ]] || die 'APFS target requires a separate synthesized-descendant audit'
  PARTITION_INFO=$(diskutil info -plist "/dev/$PARTITION_IDENTIFIER") || die "unable to inspect descendant: $PARTITION_IDENTIFIER"
  PARTITION_MOUNT=$(printf '%s' "$PARTITION_INFO" | plutil -extract MountPoint raw -o - -) || die "descendant lacks mount state: $PARTITION_IDENTIFIER"
  [[ -z "$PARTITION_MOUNT" ]] || die "target descendant is mounted: /dev/$PARTITION_IDENTIFIER at $PARTITION_MOUNT"
  PARTITION_COUNT=$((PARTITION_COUNT + 1))
  partition_index=$((partition_index + 1))
done

MOUNT_EVIDENCE=$(mount | awk -v prefix="/dev/$DEVICE_IDENTIFIER" '$1 == prefix || index($1, prefix "s") == 1 { print; exit }') || die 'unable to inspect mounted-device table'
[[ -z "$MOUNT_EVIDENCE" ]] || die "target appears in the mount table: $MOUNT_EVIDENCE"
PARTITION_MAP_SHA=$(shasum -a 256 "$LIST_PLIST_FILE" | awk '{print $1}') || die 'unable to hash partition identity'
IDENTITY_SHA=$(printf '%s\n' \
  "$DEVICE_IDENTIFIER" "$MEDIA_NAME" "$IOREGISTRY_NAME" "$DEVICE_TREE_PATH" \
  "$BUS" "$DEVICE_SIZE" "$BLOCK_SIZE" "$PARTITION_MAP_SHA" | shasum -a 256 | awk '{print $1}') || die 'unable to hash target identity'

printf '%s\n' \
  "[PASS] image hash            $IMAGE_SHA" \
  "[PASS] image size            $IMAGE_SIZE bytes" \
  '[PASS] target class          removable external physical whole disk' \
  "[PASS] target identity       media=$MEDIA_NAME registry=$IOREGISTRY_NAME bus=$BUS" \
  "[PASS] target size           $DEVICE_SIZE bytes; sector=$BLOCK_SIZE" \
  "[PASS] target path           tree=$DEVICE_TREE_PATH" \
  "[PASS] descendant mounts     none; partitions=$PARTITION_COUNT" \
  "[PASS] partition map SHA-256 $PARTITION_MAP_SHA" \
  "[PASS] identity SHA-256      $IDENTITY_SHA" \
  '' \
  'Preflight complete. No bytes were written and no mount state changed.' \
  'Record the identity hash and repeat this exact preflight immediately before' \
  'a separately reviewed writer rechecks and unmounts the same whole disk.'
