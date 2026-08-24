#!/usr/bin/env bash

# Build and inspect a regular image from an already configured ARM64 root. The
# source volume is read-only; the caller-created output volume is retained.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

SOURCE_VOLUME=''
OUTPUT_VOLUME=''
DOSFSTOOLS=/private/tmp/dosfstools-4.2-5-aarch64.pkg.tar.xz
MTOOLS='/private/tmp/mtools-1:4.0.49-1-aarch64.pkg.tar.xz'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
DOSFSTOOLS_SHA=c41120c6c89469f259d5248ea2ed0a7bea19f8a38d493682f7ff82037a862c21
MTOOLS_SHA=27b3fec3314df29d943d80f97e060d852dd60ba840f8188f25c5993e85c34f3b

usage() {
  printf '%s\n' \
    'Usage: research/test-full-image.sh --source-volume V --output-volume V [options]' \
    '' \
    'Options:' \
    '  --dosfstools FILE   Pinned Arch Linux ARM package' \
    '  --mtools FILE       Pinned Arch Linux ARM package' \
    '  --help              Show this help' \
    '' \
    'Both volumes must exist. The source is mounted read-only; the output must' \
    'be empty and is retained with the synthetic integration image.'
}

while (($# > 0)); do
  case "$1" in
    --source-volume) (($# >= 2)) || { printf 'ERROR: --source-volume requires a name\n' >&2; exit 2; }; SOURCE_VOLUME=$2; shift 2 ;;
    --output-volume) (($# >= 2)) || { printf 'ERROR: --output-volume requires a name\n' >&2; exit 2; }; OUTPUT_VOLUME=$2; shift 2 ;;
    --dosfstools) (($# >= 2)) || { printf 'ERROR: --dosfstools requires a file\n' >&2; exit 2; }; DOSFSTOOLS=$2; shift 2 ;;
    --mtools) (($# >= 2)) || { printf 'ERROR: --mtools requires a file\n' >&2; exit 2; }; MTOOLS=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for volume in "$SOURCE_VOLUME" "$OUTPUT_VOLUME"; do
  [[ "$volume" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uconsole volume name\n' >&2; exit 2; }
  docker volume inspect "$volume" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$volume" >&2; exit 2; }
done
[[ "$SOURCE_VOLUME" != "$OUTPUT_VOLUME" ]] || { printf 'ERROR: source and output volumes must differ\n' >&2; exit 2; }
[[ -f "$DOSFSTOOLS" && ! -L "$DOSFSTOOLS" ]] || { printf 'ERROR: missing dosfstools package: %s\n' "$DOSFSTOOLS" >&2; exit 2; }
[[ -f "$MTOOLS" && ! -L "$MTOOLS" ]] || { printf 'ERROR: missing mtools package: %s\n' "$MTOOLS" >&2; exit 2; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}
[[ $(sha256_file "$DOSFSTOOLS") == "$DOSFSTOOLS_SHA" ]] || { printf 'ERROR: dosfstools SHA-256 mismatch\n' >&2; exit 2; }
[[ $(sha256_file "$MTOOLS") == "$MTOOLS_SHA" ]] || { printf 'ERROR: mtools SHA-256 mismatch\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$DOSFSTOOLS,dst=/input/dosfstools.pkg.tar.xz,readonly" \
  --mount "type=bind,src=$MTOOLS,dst=/input/mtools.pkg.tar.xz,readonly" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "type=volume,src=$OUTPUT_VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/test-full-image-inside.sh
