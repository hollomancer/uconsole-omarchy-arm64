#!/usr/bin/env bash

# Reproducible, source-only build spike for yota9/uconsole-cm5 against one of
# the two pinned Arch Linux ARM Raspberry Pi header packages. The source and
# header package are mounted read-only; artifacts are staged in a new output
# directory. This script never installs a module on the host or target.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve research directory\n' >&2
  exit 2
fi

ACTION="run"
SOURCE=""
HEADERS=""
OUTPUT=""
EXPECTED_SOURCE_COMMIT='bf7a0ab55654c96b74d013520e1196d39f66391a'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: build-uconsole-dkms.sh --source DIR --headers FILE [options]' \
    '' \
    'Options:' \
    '  --check         Verify all local inputs and print the selected build; do not run Docker' \
    '  --output DIR    New artifact directory (required unless --check)' \
    '  --help          Show this help' \
    '' \
    'Accepted header packages are content-pinned in research/phase1-inputs.yaml.'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --check)
      ACTION='check'
      shift
      ;;
    --source)
      (($# >= 2)) || die '--source requires a directory'
      SOURCE=$2
      shift 2
      ;;
    --headers)
      (($# >= 2)) || die '--headers requires a file'
      HEADERS=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die '--output requires a directory'
      OUTPUT=$2
      shift 2
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

[[ -d "$SOURCE/.git" ]] || die "source is not a Git checkout: $SOURCE"
[[ -f "$HEADERS" && ! -L "$HEADERS" ]] || die "headers must be a regular, non-symlink file: $HEADERS"

SOURCE_COMMIT=$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null)
[[ "$SOURCE_COMMIT" == "$EXPECTED_SOURCE_COMMIT" ]] || die "unexpected source commit: $SOURCE_COMMIT"
SOURCE_STATUS=$(git -C "$SOURCE" status --porcelain --untracked-files=normal)
[[ -z "$SOURCE_STATUS" ]] || die 'source checkout has local or untracked changes'

HEADER_NAME=${HEADERS##*/}
case "$HEADER_NAME" in
  linux-rpi-headers-6.18.45-1-aarch64.pkg.tar.xz)
    EXPECTED_HEADERS_SHA256='1b5a819680b49c2840a3ece1c2ae638f89853050e82e8d649612dee85e82bebf'
    KERNEL_RELEASE='6.18.45-1-rpi'
    ;;
  linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz)
    EXPECTED_HEADERS_SHA256='58c5d993ff832170b2f3ca7346367272684c1fa2ff8a1bfda8d299b46a2e5d76'
    KERNEL_RELEASE='6.18.45-1-rpi-16k'
    ;;
  *)
    die "unrecognized header package: $HEADER_NAME"
    ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  HEADERS_SHA256=$(sha256sum "$HEADERS" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  HEADERS_SHA256=$(shasum -a 256 "$HEADERS" | awk '{print $1}')
else
  die 'neither sha256sum nor shasum is available'
fi
[[ "$HEADERS_SHA256" == "$EXPECTED_HEADERS_SHA256" ]] || die "header package SHA-256 mismatch: $HEADERS_SHA256"

printf '[PASS] source commit %s\n' "$SOURCE_COMMIT"
printf '[PASS] headers %s sha256=%s\n' "$HEADER_NAME" "$HEADERS_SHA256"
printf '[PASS] selected kernel release %s\n' "$KERNEL_RELEASE"
printf '[PASS] builder %s\n' "$IMAGE"

if [[ "$ACTION" == 'check' ]]; then
  printf 'Input check complete; Docker was not invoked.\n'
  exit 0
fi

[[ -n "$OUTPUT" ]] || die '--output is required for a build'
[[ ! -e "$OUTPUT" ]] || die "refusing existing output path: $OUTPUT"
case "$OUTPUT" in
  /|/dev|/dev/*) die "unsafe output path: $OUTPUT" ;;
esac
OUTPUT_PARENT=${OUTPUT%/*}
if [[ "$OUTPUT_PARENT" == "$OUTPUT" ]]; then OUTPUT_PARENT='.'; fi
[[ -d "$OUTPUT_PARENT" && -w "$OUTPUT_PARENT" ]] || die "output parent is not writable: $OUTPUT_PARENT"
command -v docker >/dev/null 2>&1 || die 'docker is required for the isolated build'

STAGING="${OUTPUT}.partial.$$"
[[ ! -e "$STAGING" ]] || die "staging path already exists: $STAGING"
mkdir "$STAGING" || die "unable to create staging directory: $STAGING"

docker run --rm --platform linux/arm64 \
  --mount "type=bind,source=$SOURCE,target=/source,readonly" \
  --mount "type=bind,source=$HEADERS,target=/input/$HEADER_NAME,readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/build-dkms-inside.sh,target=/runner.sh,readonly" \
  --mount "type=bind,source=$STAGING,target=/output" \
  --env "HEADER_NAME=$HEADER_NAME" \
  --env "HEADERS_SHA256=$HEADERS_SHA256" \
  --env "KERNEL_RELEASE=$KERNEL_RELEASE" \
  --env "SOURCE_COMMIT=$SOURCE_COMMIT" \
  --env "BUILDER_IMAGE=$IMAGE" \
  --entrypoint /bin/bash \
  "$IMAGE" /runner.sh
BUILD_STATUS=$?

if [[ $BUILD_STATUS -ne 0 ]]; then
  printf 'ERROR: isolated build failed with status %d; partial output retained at %s\n' "$BUILD_STATUS" "$STAGING" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT" || die 'failed to promote staged artifacts'
printf '[PASS] build artifacts written to %s\n' "$OUTPUT"
