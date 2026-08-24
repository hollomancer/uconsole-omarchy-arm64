#!/usr/bin/env bash

# Safe Phase 1 bootstrap scaffold.
#
# Current scope:
#   - verify a locally downloaded Arch Linux ARM rootfs by SHA-256;
#   - optionally verify its detached signature;
#   - print the pinned image-construction plan;
#   - optionally create a new sparse regular .img file.
#
# Deliberately out of scope until Linux integration tests exist:
# partitioning, loop devices, mounts, rootfs extraction and physical-device
# writes. The script never accepts a block device and never overwrites a file.

set -u
set -o pipefail

ACTION=""
ROOTFS=""
ROOTFS_SHA256=""
SIGNATURE=""
IMAGE=""
SIZE_MIB=8192

usage() {
  printf '%s\n' \
    'Usage: bootstrap-arch.sh --rootfs FILE --rootfs-sha256 HEX [options]' \
    '' \
    'Actions (choose at most one):' \
    '  --plan                 Verify inputs and print the next build stages (default)' \
    '  --create-empty-image   Create a new sparse regular .img file after verification' \
    '' \
    'Options:' \
    '  --signature FILE       Verify a detached signature with the existing GnuPG keyring' \
    '  --image FILE           New image path; required by --create-empty-image' \
    '  --size-mib N           Sparse image size in MiB (default: 8192; minimum: 1024)' \
    '  --help                 Show this help' \
    '' \
    'Physical devices are intentionally unsupported. Existing output files are never overwritten.'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

set_action() {
  local requested=$1
  if [[ -n "$ACTION" && "$ACTION" != "$requested" ]]; then
    die 'choose exactly one action'
  fi
  ACTION=$requested
}

while (($# > 0)); do
  case "$1" in
    --plan)
      set_action plan
      shift
      ;;
    --create-empty-image)
      set_action create-empty-image
      shift
      ;;
    --rootfs)
      (($# >= 2)) || die '--rootfs requires a path'
      ROOTFS=$2
      shift 2
      ;;
    --rootfs-sha256)
      (($# >= 2)) || die '--rootfs-sha256 requires a digest'
      ROOTFS_SHA256=$2
      shift 2
      ;;
    --signature)
      (($# >= 2)) || die '--signature requires a path'
      SIGNATURE=$2
      shift 2
      ;;
    --image)
      (($# >= 2)) || die '--image requires a path'
      IMAGE=$2
      shift 2
      ;;
    --size-mib)
      (($# >= 2)) || die '--size-mib requires an integer'
      SIZE_MIB=$2
      shift 2
      ;;
    --device|--write-device|--i-understand-this-erases-the-device)
      die "$1 is not implemented; this scaffold accepts regular image files only"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then ACTION='plan'; fi

[[ -n "$ROOTFS" ]] || die '--rootfs is required'
[[ -f "$ROOTFS" ]] || die "rootfs is not a regular file: $ROOTFS"
[[ ! -L "$ROOTFS" ]] || die "rootfs must not be a symbolic link: $ROOTFS"

ROOTFS_SHA256=$(printf '%s' "$ROOTFS_SHA256" | tr '[:upper:]' '[:lower:]')
[[ ${#ROOTFS_SHA256} -eq 64 ]] || die '--rootfs-sha256 must contain exactly 64 hexadecimal characters'
case "$ROOTFS_SHA256" in
  *[!0-9a-f]*) die '--rootfs-sha256 contains a non-hexadecimal character' ;;
esac

case "$SIZE_MIB" in
  ''|*[!0-9]*) die '--size-mib must be an integer' ;;
esac
((SIZE_MIB >= 1024)) || die '--size-mib must be at least 1024 MiB'

sha256_file() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    return 127
  fi
}

ACTUAL_SHA256=""
if ! ACTUAL_SHA256=$(sha256_file "$ROOTFS"); then
  die 'neither sha256sum nor shasum is available'
fi
if [[ "$ACTUAL_SHA256" != "$ROOTFS_SHA256" ]]; then
  printf 'Expected: %s\nObserved: %s\n' "$ROOTFS_SHA256" "$ACTUAL_SHA256" >&2
  die 'rootfs SHA-256 mismatch'
fi
printf '[PASS] rootfs SHA-256 %s\n' "$ACTUAL_SHA256"

if [[ -n "$SIGNATURE" ]]; then
  [[ -f "$SIGNATURE" ]] || die "signature is not a regular file: $SIGNATURE"
  [[ ! -L "$SIGNATURE" ]] || die "signature must not be a symbolic link: $SIGNATURE"
  command -v gpg >/dev/null 2>&1 || die 'gpg is required to verify the detached signature'
  if ! gpg --verify "$SIGNATURE" "$ROOTFS"; then
    die 'detached signature verification failed'
  fi
  printf '[PASS] detached signature verified with the current GnuPG keyring\n'
else
  printf '[WARN] detached signature not supplied; production input pinning requires it\n'
fi

if [[ "$ACTION" == "create-empty-image" ]]; then
  [[ -n "$IMAGE" ]] || die '--image is required by --create-empty-image'
  case "$IMAGE" in
    /dev/*) die 'paths below /dev are forbidden' ;;
    *.img) ;;
    *) die 'image path must end in .img' ;;
  esac
  [[ ! -e "$IMAGE" ]] || die "refusing to overwrite existing path: $IMAGE"
  [[ ! -L "$IMAGE" ]] || die "refusing symbolic-link output: $IMAGE"

  IMAGE_PARENT=${IMAGE%/*}
  if [[ "$IMAGE_PARENT" == "$IMAGE" ]]; then IMAGE_PARENT='.'; fi
  [[ -d "$IMAGE_PARENT" ]] || die "image parent directory does not exist: $IMAGE_PARENT"
  [[ -w "$IMAGE_PARENT" ]] || die "image parent directory is not writable: $IMAGE_PARENT"

  if ! truncate -s "${SIZE_MIB}M" "$IMAGE"; then
    die 'failed to create sparse image'
  fi
  [[ -f "$IMAGE" && ! -L "$IMAGE" ]] || die 'created output is not a regular file'
  printf '[PASS] created sparse image %s (%s MiB logical size)\n' "$IMAGE" "$SIZE_MIB"
elif [[ -n "$IMAGE" ]]; then
  printf '[WARN] --image is informational in plan mode; no file was created: %s\n' "$IMAGE"
fi

printf '%s\n' \
  '' \
  'Pinned next stages (not executed by this scaffold):' \
  '  1. Partition the regular image: FAT32 boot + ext4 root.' \
  '  2. Extract the verified rootfs with numeric ownership preserved.' \
  '  3. Install locally built, signed hardware packages in an aarch64 environment.' \
  '  4. Render config.txt, cmdline.txt and fstab from version-controlled templates.' \
  '  5. Hash every boot artifact into manifest.json.' \
  '  6. Mount the result read-only and validate ownership and boot references.' \
  '' \
  'No physical device was opened or written.'
