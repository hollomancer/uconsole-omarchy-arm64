#!/usr/bin/env bash

# Build the architecture-independent, fail-closed Omarchy userland package in
# the pinned native-aarch64 container. No network or target root is available.

set -u
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd) || exit 2
SOURCE_ARCHIVE=''
OUTPUT=''
ACTION='run'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
SOURCE_DATE_EPOCH='1787529600'

usage() {
  printf '%s\n' \
    'Usage: build-omarchy-arm64-userland.sh --source-archive FILE [options]' \
    '' \
    'Options:' \
    '  --check         Verify the pinned source and activation policies only' \
    '  --output DIR    New artifact directory (required unless --check)' \
    '  --help          Show this help'
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while (($# > 0)); do
  case "$1" in
    --source-archive) (($# >= 2)) || die '--source-archive requires a file'; SOURCE_ARCHIVE=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a directory'; OUTPUT=$2; shift 2 ;;
    --check) ACTION='check'; shift ;;
    --help|-h) usage; exit 0 ;;
    --apply|--activate|--device|--root) die "$1 is unsupported; this builder cannot modify a target" ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$SOURCE_ARCHIVE" && ! -L "$SOURCE_ARCHIVE" ]] || die 'source archive must be a regular, non-symlink file'
SOURCE_ARCHIVE_NAME=${SOURCE_ARCHIVE##*/}
SOURCE_ARCHIVE_DIR=$(dirname -- "$SOURCE_ARCHIVE") || die 'unable to resolve source archive parent'
SOURCE_ARCHIVE=$(cd -- "$SOURCE_ARCHIVE_DIR" && printf '%s/%s\n' "$PWD" "$SOURCE_ARCHIVE_NAME") || die 'unable to resolve source archive'
"$SCRIPT_DIR/audit-omarchy-activation.sh" --source-archive "$SOURCE_ARCHIVE" || die 'activation policy audit failed'
printf '[PASS] builder            %s\n' "$IMAGE"

if [[ "$ACTION" == 'check' ]]; then
  printf 'Input check complete; Docker was not invoked.\n'
  exit 0
fi

[[ -n "$OUTPUT" ]] || die '--output is required for a build'
[[ ! -e "$OUTPUT" ]] || die "refusing existing output path: $OUTPUT"
case "$OUTPUT" in /|/dev|/dev/*) die "unsafe output path: $OUTPUT" ;; esac
OUTPUT_PARENT=${OUTPUT%/*}
[[ "$OUTPUT_PARENT" != "$OUTPUT" ]] || OUTPUT_PARENT='.'
[[ -d "$OUTPUT_PARENT" && -w "$OUTPUT_PARENT" ]] || die "output parent is not writable: $OUTPUT_PARENT"
command -v docker >/dev/null 2>&1 || die 'docker is required for the isolated build'

STAGING="${OUTPUT}.partial.$$"
mkdir "$STAGING" || die 'unable to create artifact staging directory'
docker run --rm --platform linux/arm64 --network none \
  --mount "type=bind,source=$REPO_ROOT/packaging/omarchy-arm64-userland,target=/recipe,readonly" \
  --mount "type=bind,source=$REPO_ROOT/config/arm64-overrides,target=/overrides,readonly" \
  --mount "type=bind,source=$SOURCE_ARCHIVE,target=/input/omarchy-d99d4fc6.tar.gz,readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/build-omarchy-arm64-userland-inside.sh,target=/runner.sh,readonly" \
  --mount "type=bind,source=$STAGING,target=/output" \
  --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --entrypoint /bin/bash \
  "$IMAGE" /runner.sh
BUILD_STATUS=$?
if [[ $BUILD_STATUS -ne 0 ]]; then
  printf 'ERROR: package build failed with status %d; partial output retained at %s\n' "$BUILD_STATUS" "$STAGING" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT" || die 'unable to publish package artifacts'
printf '[PASS] userland artifacts written to %s\n' "$OUTPUT"
