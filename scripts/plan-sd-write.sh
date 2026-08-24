#!/usr/bin/env bash

# Read-only physical-media preflight. This script intentionally implements no
# write action; it identifies the exact image and fresh whole-disk target.

set -u
set -o pipefail

IMAGE=''
MANIFEST=''
DEVICE=''

usage() {
  printf '%s\n' \
    'Usage: plan-sd-write.sh --image FILE.img --manifest FILE.json \' \
    '  --device /dev/disk/by-id/STABLE-WHOLE-DISK' \
    '' \
    'This is a read-only Linux preflight. --write and mutable /dev/sdX names' \
    'are deliberately unsupported.'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --image) (($# >= 2)) || die '--image requires a file'; IMAGE=$2; shift 2 ;;
    --manifest) (($# >= 2)) || die '--manifest requires a file'; MANIFEST=$2; shift 2 ;;
    --device) (($# >= 2)) || die '--device requires a stable by-id path'; DEVICE=$2; shift 2 ;;
    --write|--write-device|--i-understand-this-erases-the-device) die "$1 is not implemented; this command is read-only" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || die 'SD write planning currently requires Linux lsblk/findmnt semantics'
for command_name in lsblk findmnt readlink stat sha256sum awk; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
[[ -f "$IMAGE" && ! -L "$IMAGE" ]] || die 'image must be a regular non-symlink file'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die 'manifest must be a regular non-symlink file'
case "$IMAGE" in *.img) ;; *) die 'image path must end in .img' ;; esac
case "$DEVICE" in /dev/disk/by-id/*) ;; *) die 'device must use an exact /dev/disk/by-id path' ;; esac
[[ -L "$DEVICE" ]] || die 'device by-id path must be a symbolic link managed by udev'
DEVICE_CANON=$(readlink -f -- "$DEVICE") || die 'unable to resolve device by-id path'
[[ -b "$DEVICE_CANON" ]] || die "resolved target is not a block device: $DEVICE_CANON"
[[ $(lsblk -dn -o TYPE "$DEVICE_CANON") == disk ]] || die 'target must be a whole disk, not a partition or mapper'

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
[[ "$MANIFEST_IMAGE" == "${IMAGE##*/}" ]] || die "manifest image name differs: $MANIFEST_IMAGE"
[[ "$MANIFEST_SIZE" =~ ^[0-9]+$ ]] || die 'manifest image_size is not a decimal integer'
[[ "$MANIFEST_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'manifest image_sha256 is invalid'
IMAGE_SIZE=$(stat -c '%s' "$IMAGE") || die 'unable to measure image'
[[ "$IMAGE_SIZE" == "$MANIFEST_SIZE" ]] || die "image size differs from manifest: observed=$IMAGE_SIZE expected=$MANIFEST_SIZE"
IMAGE_SHA=$(sha256sum "$IMAGE" | awk '{print $1}') || die 'unable to hash image'
[[ "$IMAGE_SHA" == "$MANIFEST_SHA" ]] || die "image SHA-256 differs from manifest: $IMAGE_SHA"

DEVICE_SIZE=$(lsblk -bdn -o SIZE "$DEVICE_CANON") || die 'unable to measure device'
[[ "$DEVICE_SIZE" =~ ^[0-9]+$ ]] || die 'device size is not numeric'
((DEVICE_SIZE >= IMAGE_SIZE)) || die "device is smaller than image: device=$DEVICE_SIZE image=$IMAGE_SIZE"

MOUNTED=$(lsblk -nrpo MOUNTPOINTS "$DEVICE_CANON" | awk 'NF { print; exit }') || die 'unable to inspect device mount state'
[[ -z "$MOUNTED" ]] || die "target or a descendant is mounted: $MOUNTED"

ROOT_SOURCE=$(findmnt -nro SOURCE /) || die 'unable to identify system root source'
if [[ "$ROOT_SOURCE" == /dev/* && -b "$ROOT_SOURCE" ]]; then
  while IFS= read -r ancestor; do
    [[ -n "$ancestor" ]] || continue
    ancestor=$(readlink -f -- "$ancestor") || die 'unable to resolve a system-root ancestor'
    [[ "$ancestor" != "$DEVICE_CANON" ]] || die 'target contains the running system root'
  done < <(lsblk -snrpo PATH "$ROOT_SOURCE")
fi

IDENTITY=$(lsblk -bdn -o PATH,MODEL,SERIAL,TRAN,SIZE,RM,RO "$DEVICE_CANON") || die 'unable to read target identity'
REMOVABLE=$(lsblk -bdn -o RM "$DEVICE_CANON" | awk '{print $1}') || die 'unable to read removable flag'
READ_ONLY=$(lsblk -bdn -o RO "$DEVICE_CANON" | awk '{print $1}') || die 'unable to read read-only flag'
[[ "$READ_ONLY" == 0 ]] || die 'target device is read-only'

printf '%s\n' \
  "[PASS] image hash            $IMAGE_SHA" \
  "[PASS] image size            $IMAGE_SIZE bytes" \
  '[PASS] target type           stable by-id whole-disk path' \
  '[PASS] target mount state    disk and descendants are unmounted' \
  '[PASS] system-disk boundary  target is not an ancestor of /' \
  '' \
  'Target identity:' \
  "$IDENTITY"
if [[ "$REMOVABLE" != 1 ]]; then
  printf '[WARN] removable flag        kernel reports RM=%s; require manual model/serial confirmation\n' "$REMOVABLE"
else
  printf '[PASS] removable flag        kernel reports RM=1\n'
fi
printf '%s\n' \
  '' \
  'Preflight complete. No bytes were written and no mount state changed.' \
  'Record this output, then use a separately reviewed writer that requires' \
  'the same by-id path, image SHA-256, model, serial and size.'
