#!/usr/bin/env bash

# Build and inspect the synthetic 8 GiB prepared-but-inactive desktop image.
# The source volume is always read-only. The output must be a distinct, empty,
# caller-created project volume and an explicit build flag is mandatory.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

SOURCE_VOLUME=''
OUTPUT_VOLUME=''
OUTPUT_DIRECTORY=''
OUTPUT_MOUNT_RO=''
OUTPUT_MOUNT_RW=''
OUTPUT_DESCRIPTION=''
ACTION='check'
ACTION_SET=0
DOSFSTOOLS=/private/tmp/dosfstools-4.2-5-aarch64.pkg.tar.xz
MTOOLS='/private/tmp/mtools-1:4.0.49-1-aarch64.pkg.tar.xz'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
DOSFSTOOLS_SHA=c41120c6c89469f259d5248ea2ed0a7bea19f8a38d493682f7ff82037a862c21
MTOOLS_SHA=27b3fec3314df29d943d80f97e060d852dd60ba840f8188f25c5993e85c34f3b
MIN_FREE_KIB=6291456
RECOMMENDED_FREE_KIB=10485760

usage() {
  printf '%s\n' \
    'Usage: research/test-omarchy-prepared-image.sh --source-volume V OUTPUT [options]' \
    '' \
    'Actions:' \
    '  --check                  Validate immutable inputs and volume identities (default)' \
    '  --probe-output           Create, loop-check and remove one 64 MiB probe file' \
    '  --build-synthetic-image  Build and retain an integration-only image in the output target' \
    '  --inspect-synthetic-image  Inspect an existing exact image without modifying it' \
    '' \
    'Options:' \
    '  --output-volume V       Empty project-only Docker volume' \
    '  --output-directory DIR  Empty project-only directory directly under /Volumes/NAME' \
    '  --dosfstools FILE        Pinned Arch Linux ARM package' \
    '  --mtools FILE            Pinned Arch Linux ARM package' \
    '  --help                   Show this help' \
    '' \
    'The source volume is mounted read-only. The output volume must be empty.' \
    'The synthetic image contains test credentials and must never be written to media or published.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
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
    --output-volume) (($# >= 2)) || die '--output-volume requires a name'; OUTPUT_VOLUME=$2; shift 2 ;;
    --output-directory) (($# >= 2)) || die '--output-directory requires a path'; OUTPUT_DIRECTORY=$2; shift 2 ;;
    --check) ((ACTION_SET == 0)) || die 'choose at most one action'; ACTION='check'; ACTION_SET=1; shift ;;
    --probe-output) ((ACTION_SET == 0)) || die 'choose at most one action'; ACTION='probe'; ACTION_SET=1; shift ;;
    --build-synthetic-image) ((ACTION_SET == 0)) || die 'choose at most one action'; ACTION='build'; ACTION_SET=1; shift ;;
    --inspect-synthetic-image) ((ACTION_SET == 0)) || die 'choose at most one action'; ACTION='inspect'; ACTION_SET=1; shift ;;
    --dosfstools) (($# >= 2)) || die '--dosfstools requires a file'; DOSFSTOOLS=$2; shift 2 ;;
    --mtools) (($# >= 2)) || die '--mtools requires a file'; MTOOLS=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --device|--write-device|--apply-in-place|--publish) die "$1 is forbidden by the synthetic-image boundary" ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$SOURCE_VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || die 'unsafe or missing uConsole source volume name'
if [[ -n "$OUTPUT_VOLUME" && -n "$OUTPUT_DIRECTORY" ]]; then
  die 'choose exactly one output target'
elif [[ -n "$OUTPUT_VOLUME" ]]; then
  [[ "$OUTPUT_VOLUME" =~ ^uconsole-omarchy-prepared-image-[a-z0-9][a-z0-9._-]*$ ]] || die 'output volume must use the uconsole-omarchy-prepared-image-* namespace'
  [[ "$SOURCE_VOLUME" != "$OUTPUT_VOLUME" ]] || die 'source and output volumes must differ'
  OUTPUT_MOUNT_RO="type=volume,src=$OUTPUT_VOLUME,dst=/output,readonly"
  OUTPUT_MOUNT_RW="type=volume,src=$OUTPUT_VOLUME,dst=/output"
  OUTPUT_DESCRIPTION="$OUTPUT_VOLUME (distinct project-only Docker volume)"
elif [[ -n "$OUTPUT_DIRECTORY" ]]; then
  [[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || die 'output directory must already exist and must not be a symlink'
  [[ "$OUTPUT_DIRECTORY" != *,* ]] || die 'output directory must not contain a comma'
  if ! OUTPUT_DIRECTORY=$(cd -- "$OUTPUT_DIRECTORY" && pwd -P); then die 'unable to resolve output directory'; fi
  [[ "$OUTPUT_DIRECTORY" =~ ^/Volumes/[^/]+/uconsole-omarchy-prepared-image-[a-z0-9][a-z0-9._-]*$ ]] || die 'output directory must be a direct, project-namespaced child of /Volumes/NAME'
  OUTPUT_MOUNT_RO="type=bind,src=$OUTPUT_DIRECTORY,dst=/output,readonly"
  OUTPUT_MOUNT_RW="type=bind,src=$OUTPUT_DIRECTORY,dst=/output"
  OUTPUT_DESCRIPTION="$OUTPUT_DIRECTORY (external project-only directory)"
else
  die 'choose exactly one of --output-volume or --output-directory'
fi
command -v docker >/dev/null 2>&1 || die 'docker is required'
docker volume inspect "$SOURCE_VOLUME" >/dev/null || die "Docker source volume does not exist: $SOURCE_VOLUME"
if [[ -n "$OUTPUT_VOLUME" ]]; then
  docker volume inspect "$OUTPUT_VOLUME" >/dev/null || die "Docker output volume does not exist: $OUTPUT_VOLUME"
fi
for package_file in "$DOSFSTOOLS" "$MTOOLS"; do
  [[ -f "$package_file" && ! -L "$package_file" ]] || die "tool package is missing or unsafe: $package_file"
done
[[ $(sha256_file "$DOSFSTOOLS") == "$DOSFSTOOLS_SHA" ]] || die 'dosfstools package SHA-256 mismatch'
[[ $(sha256_file "$MTOOLS") == "$MTOOLS_SHA" ]] || die 'mtools package SHA-256 mismatch'

printf '[PASS] source volume       %s (read-only during build)\n' "$SOURCE_VOLUME"
printf '[PASS] output target       %s\n' "$OUTPUT_DESCRIPTION"
printf '[PASS] image tools         pinned dosfstools and mtools payloads\n'
printf '[PASS] builder             %s\n' "$IMAGE"
CHECK_OUTPUT=''
if ! CHECK_OUTPUT=$(docker run --rm --platform linux/arm64 --network none \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "$OUTPUT_MOUNT_RO" \
  "$IMAGE" sh -eu -c '
      test -f /source/root/var/lib/uconsole-omarchy-arm64/hyprland-selection
      test -f /source/root/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection
      test -f /source/root/var/lib/uconsole-omarchy-arm64/user-preparation-integration
      if test "$1" = inspect; then
        test -f /output/uconsole-omarchy-prepared-integration.img
        test -f /output/uconsole-omarchy-prepared-integration.img.manifest.json
        test "$(find /output -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 2
      else
        if find /output -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
          printf "output volume is not empty\n" >&2
          exit 1
        fi
      fi
      set -- $(df -Pk /output | tail -n 1)
      printf "%s\n" "$4"
    ' uconsole-preflight "$ACTION"); then
  die 'read-only source/output volume check failed'
fi
[[ "$CHECK_OUTPUT" =~ ^[0-9]+$ ]] || die 'unable to measure output-volume free space'
if [[ "$ACTION" == inspect ]]; then
  printf '[PASS] immutable inputs    prepared source and exact image output verified read-only\n'
else
  printf '[PASS] immutable inputs    prepared source and empty output verified read-only\n'
fi
if [[ "$ACTION" == inspect ]]; then
  printf '[PASS] inspection target  exact image and manifest present; output mounted read-only\n'
elif ((CHECK_OUTPUT < MIN_FREE_KIB)); then
  printf '[FAIL] output free space   %s KiB available; %s KiB minimum required\n' "$CHECK_OUTPUT" "$MIN_FREE_KIB" >&2
  if [[ "$ACTION" == check ]]; then exit 3; fi
  die 'refusing to start a partial image build below the storage minimum'
elif ((CHECK_OUTPUT < RECOMMENDED_FREE_KIB)); then
  printf '[WARN] output free space   %s KiB available; %s KiB recommended\n' "$CHECK_OUTPUT" "$RECOMMENDED_FREE_KIB"
else
  printf '[PASS] output free space   %s KiB available\n' "$CHECK_OUTPUT"
fi
if [[ "$ACTION" == check ]]; then
  printf 'Input check complete. Neither volume was changed.\n'
  exit 0
fi

if [[ "$ACTION" == probe ]]; then
  if ! docker run --rm --privileged --platform linux/arm64 --network none \
    --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
    --mount "$OUTPUT_MOUNT_RW" \
    "$IMAGE" \
    /repo/research/container/probe-image-output-inside.sh; then
    die 'output loop-device probe failed'
  fi
  if ! docker run --rm --platform linux/arm64 --network none \
    --mount "$OUTPUT_MOUNT_RO" \
    "$IMAGE" sh -eu -c 'test -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)"'; then
    die 'output probe cleanup did not leave an empty directory'
  fi
  printf '[PASS] output probe        output is empty after the disposable loop-device check\n'
  exit 0
fi

if [[ "$ACTION" == inspect ]]; then
  docker run --rm --privileged --platform linux/arm64 --network none \
    --env UCONSOLE_IMAGE_ACTION=inspect \
    --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
    --mount "type=bind,src=$DOSFSTOOLS,dst=/input/dosfstools.pkg.tar.xz,readonly" \
    --mount "type=bind,src=$MTOOLS,dst=/input/mtools.pkg.tar.xz,readonly" \
    --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
    --mount "$OUTPUT_MOUNT_RO" \
    "$IMAGE" \
    /repo/research/container/test-omarchy-prepared-image-inside.sh
  exit $?
fi

docker run --rm --privileged --platform linux/arm64 --network none \
  --env UCONSOLE_IMAGE_ACTION=build \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$DOSFSTOOLS,dst=/input/dosfstools.pkg.tar.xz,readonly" \
  --mount "type=bind,src=$MTOOLS,dst=/input/mtools.pkg.tar.xz,readonly" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "$OUTPUT_MOUNT_RW" \
  "$IMAGE" \
  /repo/research/container/test-omarchy-prepared-image-inside.sh
