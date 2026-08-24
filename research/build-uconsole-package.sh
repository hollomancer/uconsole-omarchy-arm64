#!/usr/bin/env bash

# Reproducibly build the local-evaluation uConsole DKMS package in the same
# pinned aarch64 container used for module compilation. No host or target files
# are installed.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve research directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

HEADERS=""
SOURCE=""
OUTPUT=""
ACTION='run'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
HEADERS_SHA256='58c5d993ff832170b2f3ca7346367272684c1fa2ff8a1bfda8d299b46a2e5d76'
SOURCE_SHA256='bd03be0b091354bf6a047ca41d0c8198f124d4a12e396647fd0b0f257a7ee4e9'
SOURCE_DATE_EPOCH='1784400891'

usage() {
  printf '%s\n' \
    'Usage: build-uconsole-package.sh --headers FILE --source FILE [options]' \
    '' \
    'Options:' \
    '  --check         Verify inputs and print the build selection' \
    '  --output DIR    New output directory (required unless --check)' \
    '  --help          Show this help'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --check) ACTION='check'; shift ;;
    --headers) (($# >= 2)) || die '--headers requires a file'; HEADERS=$2; shift 2 ;;
    --source) (($# >= 2)) || die '--source requires a file'; SOURCE=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a directory'; OUTPUT=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$HEADERS" && ! -L "$HEADERS" ]] || die "headers must be a regular, non-symlink file: $HEADERS"
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || die "source must be a regular, non-symlink file: $SOURCE"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 127
  fi
}

OBSERVED_HEADERS=$(sha256_file "$HEADERS") || die 'neither sha256sum nor shasum is available'
OBSERVED_SOURCE=$(sha256_file "$SOURCE") || die 'neither sha256sum nor shasum is available'
[[ "$OBSERVED_HEADERS" == "$HEADERS_SHA256" ]] || die "header SHA-256 mismatch: $OBSERVED_HEADERS"
[[ "$OBSERVED_SOURCE" == "$SOURCE_SHA256" ]] || die "source SHA-256 mismatch: $OBSERVED_SOURCE"

HEADER_NAME=${HEADERS##*/}
SOURCE_NAME=${SOURCE##*/}
[[ "$HEADER_NAME" == 'linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz' ]] || die "unexpected header filename: $HEADER_NAME"

printf '[PASS] headers sha256=%s\n' "$OBSERVED_HEADERS"
printf '[PASS] source sha256=%s\n' "$OBSERVED_SOURCE"
printf '[PASS] builder %s\n' "$IMAGE"

if [[ "$ACTION" == 'check' ]]; then
  printf 'Input check complete; Docker was not invoked.\n'
  exit 0
fi

[[ -n "$OUTPUT" ]] || die '--output is required for a build'
[[ ! -e "$OUTPUT" ]] || die "refusing existing output path: $OUTPUT"
case "$OUTPUT" in /|/dev|/dev/*) die "unsafe output path: $OUTPUT" ;; esac
OUTPUT_PARENT=${OUTPUT%/*}
if [[ "$OUTPUT_PARENT" == "$OUTPUT" ]]; then OUTPUT_PARENT='.'; fi
[[ -d "$OUTPUT_PARENT" && -w "$OUTPUT_PARENT" ]] || die "output parent is not writable: $OUTPUT_PARENT"
command -v docker >/dev/null 2>&1 || die 'docker is required for the isolated build'

STAGING="${OUTPUT}.partial.$$"
mkdir "$STAGING" || die "unable to create staging directory: $STAGING"

docker run --rm --platform linux/arm64 \
  --mount "type=bind,source=$REPO_ROOT/packaging/uconsole-cm5-dkms,target=/package,readonly" \
  --mount "type=bind,source=$HEADERS,target=/input/$HEADER_NAME,readonly" \
  --mount "type=bind,source=$SOURCE,target=/input/$SOURCE_NAME,readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/build-board-package-inside.sh,target=/runner.sh,readonly" \
  --mount "type=bind,source=$STAGING,target=/output" \
  --env "HEADER_NAME=$HEADER_NAME" \
  --env "SOURCE_ARCHIVE_NAME=$SOURCE_NAME" \
  --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --entrypoint /bin/bash \
  "$IMAGE" /runner.sh
BUILD_STATUS=$?

if [[ $BUILD_STATUS -ne 0 ]]; then
  printf 'ERROR: package build failed with status %d; partial output retained at %s\n' "$BUILD_STATUS" "$STAGING" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT" || die 'failed to promote package artifacts'
printf '[PASS] package artifacts written to %s\n' "$OUTPUT"

