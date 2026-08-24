#!/usr/bin/env bash

# Compare two completed synthetic images read-only. Both containing directories
# must be distinct, project-namespaced children of mounted external volumes.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

IMAGE_A_DIR=''
IMAGE_B_DIR=''
ACTION=compare
BUILDER_IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/compare-omarchy-prepared-images.sh --image-a-dir DIR --image-b-dir DIR' \
    '' \
    '  --diagnose-metadata  Skip content hashing and report timestamp/superblock variance' \
    '' \
    'Both directories are mounted read-only. No image or physical device is modified.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --image-a-dir) (($# >= 2)) || die '--image-a-dir requires a path'; IMAGE_A_DIR=$2; shift 2 ;;
    --image-b-dir) (($# >= 2)) || die '--image-b-dir requires a path'; IMAGE_B_DIR=$2; shift 2 ;;
    --diagnose-metadata) ACTION=metadata; shift ;;
    --device|--write-device|--delete|--publish) die "$1 is forbidden by the read-only comparison boundary" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

validate_image_dir() {
  local label=$1
  local candidate=$2
  local resolved=''
  [[ -d "$candidate" && ! -L "$candidate" ]] || die "$label must exist and must not be a symlink"
  [[ "$candidate" != *,* ]] || die "$label must not contain a comma"
  if ! resolved=$(cd -- "$candidate" && pwd -P); then die "unable to resolve $label"; fi
  [[ "$resolved" =~ ^/Volumes/[^/]+/uconsole-omarchy-prepared-image-[a-z0-9][a-z0-9._-]*$ ]] || die "$label is outside the external project namespace"
  [[ -f "$resolved/uconsole-omarchy-prepared-integration.img" && ! -L "$resolved/uconsole-omarchy-prepared-integration.img" ]] || die "$label lacks the exact regular image"
  [[ -f "$resolved/uconsole-omarchy-prepared-integration.img.manifest.json" && ! -L "$resolved/uconsole-omarchy-prepared-integration.img.manifest.json" ]] || die "$label lacks the exact regular manifest"
  [[ $(find "$resolved" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ') -eq 2 ]] || die "$label contains unexpected entries"
  printf '%s\n' "$resolved"
}

IMAGE_A_DIR=$(validate_image_dir 'image A directory' "$IMAGE_A_DIR")
IMAGE_B_DIR=$(validate_image_dir 'image B directory' "$IMAGE_B_DIR")
[[ "$IMAGE_A_DIR" != "$IMAGE_B_DIR" ]] || die 'image directories must differ'
command -v docker >/dev/null 2>&1 || die 'docker is required'

printf '[PASS] image A directory   %s\n' "$IMAGE_A_DIR"
printf '[PASS] image B directory   %s\n' "$IMAGE_B_DIR"
if [[ "$ACTION" == metadata ]]; then
  CONTAINER_RUNNER=/repo/research/container/diagnose-omarchy-image-metadata-inside.sh
else
  CONTAINER_RUNNER=/repo/research/container/compare-omarchy-prepared-images-inside.sh
fi
docker run --rm --privileged --platform linux/arm64 --network none \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$IMAGE_A_DIR,dst=/image-a,readonly" \
  --mount "type=bind,src=$IMAGE_B_DIR,dst=/image-b,readonly" \
  "$BUILDER_IMAGE" \
  "$CONTAINER_RUNNER"
