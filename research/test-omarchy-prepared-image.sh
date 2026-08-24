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
ACTION='check'
DOSFSTOOLS=/private/tmp/dosfstools-4.2-5-aarch64.pkg.tar.xz
MTOOLS='/private/tmp/mtools-1:4.0.49-1-aarch64.pkg.tar.xz'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
DOSFSTOOLS_SHA=c41120c6c89469f259d5248ea2ed0a7bea19f8a38d493682f7ff82037a862c21
MTOOLS_SHA=27b3fec3314df29d943d80f97e060d852dd60ba840f8188f25c5993e85c34f3b

usage() {
  printf '%s\n' \
    'Usage: research/test-omarchy-prepared-image.sh --source-volume V --output-volume V [options]' \
    '' \
    'Actions:' \
    '  --check                  Validate immutable inputs and volume identities (default)' \
    '  --build-synthetic-image  Build and retain an integration-only image in the output volume' \
    '' \
    'Options:' \
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
    --check) ACTION='check'; shift ;;
    --build-synthetic-image) ACTION='build'; shift ;;
    --dosfstools) (($# >= 2)) || die '--dosfstools requires a file'; DOSFSTOOLS=$2; shift 2 ;;
    --mtools) (($# >= 2)) || die '--mtools requires a file'; MTOOLS=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --device|--write-device|--apply-in-place|--publish) die "$1 is forbidden by the synthetic-image boundary" ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$SOURCE_VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || die 'unsafe or missing uConsole source volume name'
[[ "$OUTPUT_VOLUME" =~ ^uconsole-omarchy-prepared-image-[a-z0-9][a-z0-9._-]*$ ]] || die 'output volume must use the uconsole-omarchy-prepared-image-* namespace'
[[ "$SOURCE_VOLUME" != "$OUTPUT_VOLUME" ]] || die 'source and output volumes must differ'
command -v docker >/dev/null 2>&1 || die 'docker is required'
docker volume inspect "$SOURCE_VOLUME" >/dev/null || die "Docker source volume does not exist: $SOURCE_VOLUME"
docker volume inspect "$OUTPUT_VOLUME" >/dev/null || die "Docker output volume does not exist: $OUTPUT_VOLUME"
for package_file in "$DOSFSTOOLS" "$MTOOLS"; do
  [[ -f "$package_file" && ! -L "$package_file" ]] || die "tool package is missing or unsafe: $package_file"
done
[[ $(sha256_file "$DOSFSTOOLS") == "$DOSFSTOOLS_SHA" ]] || die 'dosfstools package SHA-256 mismatch'
[[ $(sha256_file "$MTOOLS") == "$MTOOLS_SHA" ]] || die 'mtools package SHA-256 mismatch'

printf '[PASS] source volume       %s (read-only during build)\n' "$SOURCE_VOLUME"
printf '[PASS] output volume       %s (distinct project-only namespace)\n' "$OUTPUT_VOLUME"
printf '[PASS] image tools         pinned dosfstools and mtools payloads\n'
printf '[PASS] builder             %s\n' "$IMAGE"
if [[ "$ACTION" == check ]]; then
  if ! docker run --rm --platform linux/arm64 --network none \
    --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
    --mount "type=volume,src=$OUTPUT_VOLUME,dst=/output,readonly" \
    "$IMAGE" sh -eu -c '
      test -f /source/root/var/lib/uconsole-omarchy-arm64/hyprland-selection
      test -f /source/root/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection
      test -f /source/root/var/lib/uconsole-omarchy-arm64/user-preparation-integration
      if find /output -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        printf "output volume is not empty\n" >&2
        exit 1
      fi
    '; then
    die 'read-only source/output volume check failed'
  fi
  printf 'Input check complete. A read-only container verified the prepared source and empty output; neither volume was changed.\n'
  exit 0
fi

docker run --rm --privileged --platform linux/arm64 --network none \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$DOSFSTOOLS,dst=/input/dosfstools.pkg.tar.xz,readonly" \
  --mount "type=bind,src=$MTOOLS,dst=/input/mtools.pkg.tar.xz,readonly" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "type=volume,src=$OUTPUT_VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/test-omarchy-prepared-image-inside.sh
