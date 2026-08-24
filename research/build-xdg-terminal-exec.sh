#!/usr/bin/env bash

# Reproducibly build and test the architecture-independent terminal dispatcher
# in the pinned aarch64 Arch Linux ARM container. Inputs are mounted read-only;
# no package is installed on the host or target.

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

SOURCE=""
SCDOC=""
BATS=""
PARALLEL=""
OUTPUT=""
ACTION='run'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
SOURCE_DATE_EPOCH='1785330660'

usage() {
  printf '%s\n' \
    'Usage: build-xdg-terminal-exec.sh --source FILE --scdoc FILE --bats FILE --parallel FILE [options]' \
    '' \
    'Options:' \
    '  --check         Verify inputs and print the build selection' \
    '  --output DIR    New output directory (required unless --check)' \
    '  --help          Show this help'
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

while (($# > 0)); do
  case "$1" in
    --check) ACTION='check'; shift ;;
    --source) (($# >= 2)) || die '--source requires a file'; SOURCE=$2; shift 2 ;;
    --scdoc) (($# >= 2)) || die '--scdoc requires a file'; SCDOC=$2; shift 2 ;;
    --bats) (($# >= 2)) || die '--bats requires a file'; BATS=$2; shift 2 ;;
    --parallel) (($# >= 2)) || die '--parallel requires a file'; PARALLEL=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a directory'; OUTPUT=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

verify_input() {
  local label=$1
  local path=$2
  local expected_name=$3
  local expected_sha=$4
  local observed=""
  [[ -f "$path" && ! -L "$path" ]] || die "$label must be a regular, non-symlink file: $path"
  [[ "${path##*/}" == "$expected_name" ]] || die "unexpected $label filename: ${path##*/}"
  observed=$(sha256_file "$path") || die 'neither sha256sum nor shasum is available'
  [[ "$observed" == "$expected_sha" ]] || die "$label SHA-256 mismatch: $observed"
  printf '[PASS] %-10s sha256=%s\n' "$label" "$observed"
}

verify_input source "$SOURCE" xdg-terminal-exec-v0.14.3.tar.gz bfa291f6ad70fc61abd0b45510b799cb24c1c11f0b5cdc7b7538169688f1df79
verify_input scdoc "$SCDOC" scdoc-1.11.5-1-aarch64.pkg.tar.xz d8afceb6ff7714f0b0086062a26c0296661f7532e69ec2143155fdbbd466175b
verify_input bats "$BATS" bats-1.14.0-1-any.pkg.tar.xz 7bc31235cfe496b982698980b14c9c14b3e17f2b71ee13f72a58271ed199710a
verify_input parallel "$PARALLEL" parallel-20260722-1-any.pkg.tar.xz d7109181105460a5d5fbac92d27638c285431e11c9f43832abaa345445e24a76
printf '[PASS] builder    %s\n' "$IMAGE"

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
  --mount "type=bind,source=$REPO_ROOT/packaging/xdg-terminal-exec,target=/package,readonly" \
  --mount "type=bind,source=$SOURCE,target=/input/${SOURCE##*/},readonly" \
  --mount "type=bind,source=$SCDOC,target=/input/${SCDOC##*/},readonly" \
  --mount "type=bind,source=$BATS,target=/input/${BATS##*/},readonly" \
  --mount "type=bind,source=$PARALLEL,target=/input/${PARALLEL##*/},readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/build-xdg-terminal-exec-inside.sh,target=/runner.sh,readonly" \
  --mount "type=bind,source=$STAGING,target=/output" \
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
