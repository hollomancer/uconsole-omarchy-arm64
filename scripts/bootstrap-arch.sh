#!/usr/bin/env bash

# Safe Phase 1 Arch Linux ARM root bootstrap.
#
# Scope:
#   - verify a locally downloaded Arch Linux ARM rootfs by SHA-256;
#   - verify its detached signature against an explicit keyring/fingerprint;
#   - extract it into a new offline root with Linux ownership semantics;
#   - optionally create a new sparse regular .img file.
#
# Image partitioning/population belongs to build-image.sh. This script never
# accepts a block device and never overwrites a path.

set -u
set -o pipefail

ACTION=""
ROOTFS=""
ROOTFS_SHA256=""
SIGNATURE=""
KEYRING=""
SIGNER_FINGERPRINT=""
ROOT_TREE=""
IMAGE=""
SIZE_MIB=8192

usage() {
  printf '%s\n' \
    'Usage: bootstrap-arch.sh --rootfs FILE --rootfs-sha256 HEX [options]' \
    '' \
    'Actions (choose at most one):' \
    '  --plan                 Verify inputs and print the next build stages (default)' \
    '  --extract-root         Extract into a new offline root (Linux root only)' \
    '  --create-empty-image   Create a new sparse regular .img file after verification' \
    '' \
    'Options:' \
    '  --signature FILE       Detached rootfs signature' \
    '  --keyring FILE         Explicit trusted OpenPGP keyring for gpgv' \
    '  --signer-fingerprint F Exact expected 40-hex signing fingerprint' \
    '  --root-tree DIR        New destination required by --extract-root' \
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
    --extract-root)
      set_action extract-root
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
    --keyring)
      (($# >= 2)) || die '--keyring requires a path'
      KEYRING=$2
      shift 2
      ;;
    --signer-fingerprint)
      (($# >= 2)) || die '--signer-fingerprint requires 40 hexadecimal characters'
      SIGNER_FINGERPRINT=$2
      shift 2
      ;;
    --root-tree)
      (($# >= 2)) || die '--root-tree requires a directory path'
      ROOT_TREE=$2
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

SIGNATURE_VERIFIED=0
if [[ -n "$SIGNATURE" || -n "$KEYRING" || -n "$SIGNER_FINGERPRINT" ]]; then
  [[ -n "$SIGNATURE" && -n "$KEYRING" && -n "$SIGNER_FINGERPRINT" ]] || die '--signature, --keyring and --signer-fingerprint must be supplied together'
  [[ -f "$SIGNATURE" ]] || die "signature is not a regular file: $SIGNATURE"
  [[ ! -L "$SIGNATURE" ]] || die "signature must not be a symbolic link: $SIGNATURE"
  [[ -f "$KEYRING" ]] || die "keyring is not a regular file: $KEYRING"
  [[ ! -L "$KEYRING" ]] || die "keyring must not be a symbolic link: $KEYRING"
  SIGNER_FINGERPRINT=$(printf '%s' "$SIGNER_FINGERPRINT" | tr '[:lower:]' '[:upper:]')
  [[ "$SIGNER_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] || die '--signer-fingerprint must contain exactly 40 hexadecimal characters'
  command -v gpgv >/dev/null 2>&1 || die 'gpgv is required to verify the detached signature'
  GPG_STATUS=''
  if ! GPG_STATUS=$(gpgv --status-fd 1 --keyring "$KEYRING" "$SIGNATURE" "$ROOTFS" 2>&1); then
    printf '%s\n' "$GPG_STATUS" >&2
    die 'detached signature verification failed'
  fi
  VALID_FINGERPRINT=$(printf '%s\n' "$GPG_STATUS" | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { count++; value=$3 } END { if (count == 1) print value; else exit 1 }') || die 'gpgv did not report exactly one valid signature fingerprint'
  [[ "$VALID_FINGERPRINT" == "$SIGNER_FINGERPRINT" ]] || die "valid signature used unexpected fingerprint: $VALID_FINGERPRINT"
  SIGNATURE_VERIFIED=1
  printf '[PASS] detached signature %s\n' "$VALID_FINGERPRINT"
else
  printf '[WARN] detached signature not supplied; --extract-root requires it\n'
fi

if [[ "$ACTION" == "extract-root" ]]; then
  [[ $SIGNATURE_VERIFIED -eq 1 ]] || die '--extract-root requires a verified detached signature, explicit keyring and expected fingerprint'
  [[ "$(uname -s)" == 'Linux' ]] || die '--extract-root requires Linux ownership and xattr semantics'
  [[ $EUID -eq 0 ]] || die '--extract-root requires root to preserve numeric ownership'
  command -v bsdtar >/dev/null 2>&1 || die 'bsdtar is required to extract the rootfs'
  [[ -n "$ROOT_TREE" ]] || die '--root-tree is required by --extract-root'
  case "$ROOT_TREE" in /|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*) die "unsafe root destination: $ROOT_TREE" ;; esac
  [[ ! -e "$ROOT_TREE" && ! -L "$ROOT_TREE" ]] || die "refusing existing root destination: $ROOT_TREE"
  ROOT_PARENT=${ROOT_TREE%/*}
  ROOT_NAME=${ROOT_TREE##*/}
  if [[ "$ROOT_PARENT" == "$ROOT_TREE" ]]; then ROOT_PARENT='.'; fi
  [[ "$ROOT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'root destination name may contain only letters, digits, dot, underscore or hyphen'
  [[ -d "$ROOT_PARENT" && -w "$ROOT_PARENT" ]] || die "root destination parent is not writable: $ROOT_PARENT"
  ROOT_PARENT=$(cd -- "$ROOT_PARENT" && pwd -P) || die 'unable to resolve root destination parent'
  case "$ROOT_PARENT" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*) die "unsafe resolved root destination parent: $ROOT_PARENT" ;; esac
  ROOT_TREE="$ROOT_PARENT/$ROOT_NAME"
  PARTIAL_ROOT="${ROOT_TREE}.partial.$$"
  [[ ! -e "$PARTIAL_ROOT" && ! -L "$PARTIAL_ROOT" ]] || die "partial root destination already exists: $PARTIAL_ROOT"

  UNSAFE_ARCHIVE_PATH=''
  UNSAFE_ARCHIVE_PATH=$(bsdtar -tf "$ROOTFS" | awk '
    function unsafe(path, count, parts, part_index) {
      if (substr(path, 1, 1) == "/") return 1
      count=split(path, parts, "/")
      for (part_index=1; part_index<=count; part_index++) if (parts[part_index] == "..") return 1
      return 0
    }
    unsafe($0) { print; exit }
  ') || die 'unable to inspect rootfs archive paths'
  [[ -z "$UNSAFE_ARCHIVE_PATH" ]] || die "rootfs contains an unsafe path: $UNSAFE_ARCHIVE_PATH"

  mkdir "$PARTIAL_ROOT" || die 'unable to create partial root destination'
  if ! bsdtar -xpf "$ROOTFS" --numeric-owner --acls --xattrs --no-fflags -C "$PARTIAL_ROOT"; then
    printf 'Partial extraction retained for diagnosis: %s\n' "$PARTIAL_ROOT" >&2
    die 'rootfs extraction failed'
  fi
  [[ -f "$PARTIAL_ROOT/etc/os-release" ]] || die "extracted root lacks /etc/os-release; partial retained: $PARTIAL_ROOT"
  grep -Eq '^ID=(archarm|arch)$|^NAME="?Arch Linux ARM"?$' "$PARTIAL_ROOT/etc/os-release" || die "extracted root has unexpected OS identity; partial retained: $PARTIAL_ROOT"
  [[ -d "$PARTIAL_ROOT/boot" && -d "$PARTIAL_ROOT/var/lib/pacman/local" ]] || die "extracted root lacks boot or pacman state; partial retained: $PARTIAL_ROOT"
  mkdir -p "$PARTIAL_ROOT/var/lib/uconsole-omarchy-arm64" || die "unable to create root selection state; partial retained: $PARTIAL_ROOT"
  {
    printf 'rootfs_sha256=%s\n' "$ACTUAL_SHA256"
    printf 'signature_fingerprint=%s\n' "$VALID_FINGERPRINT"
    printf 'archive_name=%s\n' "${ROOTFS##*/}"
  } > "$PARTIAL_ROOT/var/lib/uconsole-omarchy-arm64/rootfs-selection" || die "unable to write root selection state; partial retained: $PARTIAL_ROOT"
  chmod 0644 "$PARTIAL_ROOT/var/lib/uconsole-omarchy-arm64/rootfs-selection" || die "unable to set root selection mode; partial retained: $PARTIAL_ROOT"
  mv "$PARTIAL_ROOT" "$ROOT_TREE" || die "unable to promote extracted root; partial retained: $PARTIAL_ROOT"
  printf '[PASS] extracted offline Arch Linux ARM root %s\n' "$ROOT_TREE"
elif [[ "$ACTION" == "create-empty-image" ]]; then
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
  'Pinned next stages:' \
  '  1. Extract the signed rootfs with --extract-root in Linux.' \
  '  2. Install the locked hardware packages into that offline root.' \
  '  3. Apply minimal console/network/SSH configuration.' \
  '  4. Build a regular image with scripts/build-image.sh.' \
  '  5. Mount the result read-only and run validation.' \
  '' \
  'No physical device was opened or written.'
