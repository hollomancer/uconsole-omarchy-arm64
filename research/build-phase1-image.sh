#!/usr/bin/env bash

# Build/check/inspect the real operator-configured Phase 1 image. The source is
# always read-only and output is restricted to a namespaced external directory.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

ACTION=check
ACTION_SET=0
SOURCE_VOLUME=''
CONFIRM_SOURCE_VOLUME=''
OUTPUT_DIRECTORY=''
DISK_ID=''
BOOT_ID=''
ROOT_UUID=''
SOURCE_DATE_EPOCH=''
DOSFSTOOLS=/private/tmp/dosfstools-4.2-5-aarch64.pkg.tar.xz
MTOOLS='/private/tmp/mtools-1:4.0.49-1-aarch64.pkg.tar.xz'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
DOSFSTOOLS_SHA=c41120c6c89469f259d5248ea2ed0a7bea19f8a38d493682f7ff82037a862c21
MTOOLS_SHA=27b3fec3314df29d943d80f97e060d852dd60ba840f8188f25c5993e85c34f3b
MIN_FREE_KIB=6291456
RECOMMENDED_FREE_KIB=10485760

usage() {
  printf '%s\n' \
    'Usage: research/build-phase1-image.sh --source-volume V --output-directory DIR \' \
    '  --disk-id HEX8 --boot-id HEX8 --root-uuid UUID \' \
    '  --source-date-epoch EPOCH [action]' \
    '' \
    'Actions:' \
    '  --check          Run the production image plan; output must remain empty (default)' \
    '  --build-image    Build and inspect the 8 GiB Phase 1 image' \
    '  --inspect-image  Reinspect an existing exact image and manifest read-only' \
    '' \
    'Options:' \
    '  --confirm-source-volume V  Required with --build-image; exact repeat of source' \
    '  --dosfstools FILE           Pinned Arch Linux ARM package' \
    '  --mtools FILE               Pinned Arch Linux ARM package' \
    '  --help                      Show this help' \
    '' \
    'No physical device is accepted. Hyprland and Omarchy state are forbidden.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

set_action() {
  local requested=$1
  [[ $ACTION_SET -eq 0 ]] || die 'choose exactly one action'
  ACTION=$requested
  ACTION_SET=1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

while (($# > 0)); do
  case "$1" in
    --source-volume) (($# >= 2)) || die '--source-volume requires a name'; SOURCE_VOLUME=$2; shift 2 ;;
    --confirm-source-volume) (($# >= 2)) || die '--confirm-source-volume requires a name'; CONFIRM_SOURCE_VOLUME=$2; shift 2 ;;
    --output-directory) (($# >= 2)) || die '--output-directory requires a path'; OUTPUT_DIRECTORY=$2; shift 2 ;;
    --disk-id) (($# >= 2)) || die '--disk-id requires a value'; DISK_ID=$2; shift 2 ;;
    --boot-id) (($# >= 2)) || die '--boot-id requires a value'; BOOT_ID=$2; shift 2 ;;
    --root-uuid) (($# >= 2)) || die '--root-uuid requires a value'; ROOT_UUID=$2; shift 2 ;;
    --source-date-epoch) (($# >= 2)) || die '--source-date-epoch requires a value'; SOURCE_DATE_EPOCH=$2; shift 2 ;;
    --dosfstools) (($# >= 2)) || die '--dosfstools requires a file'; DOSFSTOOLS=$2; shift 2 ;;
    --mtools) (($# >= 2)) || die '--mtools requires a file'; MTOOLS=$2; shift 2 ;;
    --check) set_action check; shift ;;
    --build-image) set_action build; shift ;;
    --inspect-image) set_action inspect; shift ;;
    --device|--write-device|--publish|--require-omarchy-prepared) die "$1 is forbidden by the Phase 1 image boundary" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$SOURCE_VOLUME" =~ ^uconsole-phase1-operator-pending-[0-9]{8}$ ]] || die 'source volume must use uconsole-phase1-operator-pending-YYYYMMDD'
if [[ "$ACTION" == build ]]; then
  [[ "$CONFIRM_SOURCE_VOLUME" == "$SOURCE_VOLUME" ]] || die '--build-image requires --confirm-source-volume with the exact source name'
elif [[ -n "$CONFIRM_SOURCE_VOLUME" ]]; then
  die '--confirm-source-volume is accepted only with --build-image'
fi
[[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" && "$OUTPUT_DIRECTORY" != *,* ]] || die 'output directory is missing or unsafe'
OUTPUT_DIRECTORY=$(cd -- "$OUTPUT_DIRECTORY" && pwd -P) || die 'unable to resolve output directory'
[[ "$OUTPUT_DIRECTORY" =~ ^/Volumes/[^/]+/uconsole-phase1-image-[a-z0-9][a-z0-9._-]*$ ]] || die 'output must be a direct namespaced child of an external volume'

DISK_ID=$(printf '%s' "$DISK_ID" | tr '[:upper:]' '[:lower:]')
BOOT_ID=$(printf '%s' "$BOOT_ID" | tr '[:lower:]' '[:upper:]')
ROOT_UUID=$(printf '%s' "$ROOT_UUID" | tr '[:upper:]' '[:lower:]')
[[ "$DISK_ID" =~ ^[0-9a-f]{8}$ && "$DISK_ID" != 00000000 ]] || die 'disk ID must be eight nonzero hexadecimal characters'
[[ "$BOOT_ID" =~ ^[0-9A-F]{8}$ && "$BOOT_ID" != 00000000 ]] || die 'boot ID must be eight nonzero hexadecimal characters'
[[ "$ROOT_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die 'root UUID must be an RFC 4122 UUID'
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ && "$SOURCE_DATE_EPOCH" -gt 0 ]] || die 'source date epoch must be positive'

for package_file in "$DOSFSTOOLS" "$MTOOLS"; do
  [[ -f "$package_file" && ! -L "$package_file" ]] || die "tool package is missing or unsafe: $package_file"
done
[[ $(sha256_file "$DOSFSTOOLS") == "$DOSFSTOOLS_SHA" ]] || die 'dosfstools package SHA-256 mismatch'
[[ $(sha256_file "$MTOOLS") == "$MTOOLS_SHA" ]] || die 'mtools package SHA-256 mismatch'
command -v docker >/dev/null 2>&1 || die 'docker is required'
docker volume inspect "$SOURCE_VOLUME" >/dev/null || die "source volume does not exist: $SOURCE_VOLUME"
CONTAINER_REFERENCES=$(docker ps -aq --filter "volume=$SOURCE_VOLUME") || die 'unable to inspect source-volume references'
[[ -z "$CONTAINER_REFERENCES" ]] || die 'source volume is referenced by a container'

EXPECTED_ENTRIES=0
if [[ "$ACTION" == inspect ]]; then EXPECTED_ENTRIES=2; fi
OUTPUT_ENTRIES=$(find "$OUTPUT_DIRECTORY" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')
[[ "$OUTPUT_ENTRIES" -eq "$EXPECTED_ENTRIES" ]] || die "output directory entry count differs: $OUTPUT_ENTRIES"
if [[ "$ACTION" == inspect ]]; then
  [[ -f "$OUTPUT_DIRECTORY/uconsole-phase1-cm5.img" && ! -L "$OUTPUT_DIRECTORY/uconsole-phase1-cm5.img" ]] || die 'existing Phase 1 image is missing or unsafe'
  [[ -f "$OUTPUT_DIRECTORY/uconsole-phase1-cm5.img.manifest.json" && ! -L "$OUTPUT_DIRECTORY/uconsole-phase1-cm5.img.manifest.json" ]] || die 'existing Phase 1 manifest is missing or unsafe'
fi

OUTPUT_FREE_KIB=$(df -Pk "$OUTPUT_DIRECTORY" | awk 'NR == 2 {print $4}') || die 'unable to measure output free space'
[[ "$OUTPUT_FREE_KIB" =~ ^[0-9]+$ ]] || die 'output free-space measurement is invalid'
if [[ "$ACTION" != inspect && "$OUTPUT_FREE_KIB" -lt "$MIN_FREE_KIB" ]]; then die 'output has less than the 6 GiB build minimum'; fi
if [[ "$ACTION" != inspect && "$OUTPUT_FREE_KIB" -lt "$RECOMMENDED_FREE_KIB" ]]; then
  printf '[WARN] output free space   %s KiB available; %s KiB recommended\n' "$OUTPUT_FREE_KIB" "$RECOMMENDED_FREE_KIB"
else
  printf '[PASS] output free space   %s KiB available\n' "$OUTPUT_FREE_KIB"
fi

COMMON_DOCKER_ARGS=(
  --platform linux/arm64 --network none --log-driver none
  --env "UCONSOLE_IMAGE_ACTION=$ACTION"
  --env "UCONSOLE_DISK_ID=$DISK_ID"
  --env "UCONSOLE_BOOT_ID=$BOOT_ID"
  --env "UCONSOLE_ROOT_UUID=$ROOT_UUID"
  --env "UCONSOLE_SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly"
  --mount "type=bind,src=$DOSFSTOOLS,dst=/input/dosfstools.pkg.tar.xz,readonly"
  --mount "type=bind,src=$MTOOLS,dst=/input/mtools.pkg.tar.xz,readonly"
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly"
)

if [[ "$ACTION" == check ]]; then
  docker run --rm --read-only "${COMMON_DOCKER_ARGS[@]}" \
    --mount "type=bind,src=$OUTPUT_DIRECTORY,dst=/output" \
    "$IMAGE" /repo/research/container/build-phase1-image-inside.sh
  exit $?
fi

OUTPUT_MOUNT="type=bind,src=$OUTPUT_DIRECTORY,dst=/output"
if [[ "$ACTION" == inspect ]]; then OUTPUT_MOUNT="$OUTPUT_MOUNT,readonly"; fi
docker run --rm --privileged "${COMMON_DOCKER_ARGS[@]}" \
  --mount "$OUTPUT_MOUNT" \
  "$IMAGE" /repo/research/container/build-phase1-image-inside.sh
