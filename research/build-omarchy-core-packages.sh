#!/usr/bin/env bash

# Build and test the five remaining core Omarchy packages in one pinned native-
# aarch64 container. Sources and dependencies are read-only and content-locked;
# no package is installed on the host or target.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

SOURCE_DIR=''
DEPENDENCY_DIR=''
OUTPUT=''
ACTION=run
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
SOURCE_DATE_EPOCH=1787529600
LOCK="$SCRIPT_DIR/omarchy-core-build-transaction.lock"

usage() {
  printf '%s\n' \
    'Usage: research/build-omarchy-core-packages.sh --source-dir DIR --dependency-dir DIR [options]' \
    '' \
    'Options:' \
    '  --check         Verify every source/dependency input; do not run Docker' \
    '  --output DIR    New artifact directory (required unless --check)' \
    '  --help          Show this help'
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

while (($# > 0)); do
  case "$1" in
    --check) ACTION=check; shift ;;
    --source-dir) (($# >= 2)) || die '--source-dir requires a directory'; SOURCE_DIR=$2; shift 2 ;;
    --dependency-dir) (($# >= 2)) || die '--dependency-dir requires a directory'; DEPENDENCY_DIR=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a directory'; OUTPUT=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --apply|--activate|--device|--root) die "$1 is not supported; this is an isolated package builder" ;;
    *) die "unknown option: $1" ;;
  esac
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}
file_size() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then stat -f '%z' "$1"
  else stat -c '%s' "$1"
  fi
}
verify_input() {
  local filename=$1
  local expected_size=$2
  local expected_sha=$3
  local path="$SOURCE_DIR/$filename"
  [[ -f "$path" && ! -L "$path" ]] || die "source must be a regular, non-symlink file: $filename"
  [[ $(file_size "$path") == "$expected_size" ]] || die "source size mismatch: $filename"
  [[ $(sha256_file "$path") == "$expected_sha" ]] || die "source SHA-256 mismatch: $filename"
  printf '[PASS] source %-34s sha256=%s\n' "$filename" "$expected_sha"
}

[[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || die 'source directory is missing or a symlink'
[[ -d "$DEPENDENCY_DIR" && ! -L "$DEPENDENCY_DIR" ]] || die 'dependency directory is missing or a symlink'
SOURCE_DIR=$(cd -- "$SOURCE_DIR" && pwd -P) || die 'cannot resolve source directory'
DEPENDENCY_DIR=$(cd -- "$DEPENDENCY_DIR" && pwd -P) || die 'cannot resolve dependency directory'
verify_input omacalc-0.2.2.tar.gz 262911 a42b39cd5a62c83f6667060da19c9bcc5dd8469ce69e48f19394b71322b9cba4
verify_input omacut-0.4.0.tar.gz 30695 0e1b0665e0304a1ecbdb06b8574e8abf385e1cffa431821032902340c2c5d7df
verify_input ia-fonts-b337fe1a.tar.gz 4890621 ac34b1494e58e28aadce1220a342757a29225dc84d2ee83748dca047927e5792
verify_input ttfx-0.3.2.tar.gz 5634314 d0c0df4867e7f03142fb7f77c66670d0e8da15534239c1a7abfd89f19dfc00f6
verify_input ttfx-0.3.2-vendor.tar.zst 5300648 3063230b60a7916574432f4343d8d16747ba61ba15921ee6a84a14cd0c45b887
verify_input yaru-26.04.5.1ubuntu.tar.gz 79046054 4e35b71d37aedb44302c811f63d325f4abd7699961f76f130323b361d4c6a7d7

[[ -f "$DEPENDENCY_DIR/transaction.lock" && ! -L "$DEPENDENCY_DIR/transaction.lock" ]] || die 'dependency transaction.lock is missing or unsafe'
cmp -s "$DEPENDENCY_DIR/transaction.lock" "$LOCK" || die 'dependency transaction lock differs from the committed lock'
dependency_count=0
while IFS='|' read -r _ _ _ _ _ package_sha signature_sha filename size extra; do
  [[ -n "$filename" && "$filename" != filename ]] || continue
  [[ -z "${extra:-}" ]] || die "invalid dependency lock row: $filename"
  package="$DEPENDENCY_DIR/$filename"
  signature="${package}.sig"
  [[ -f "$package" && ! -L "$package" && -f "$signature" && ! -L "$signature" ]] || die "locked dependency payload is missing or unsafe: $filename"
  [[ $(file_size "$package") == "$size" ]] || die "dependency size mismatch: $filename"
  [[ $(sha256_file "$package") == "$package_sha" ]] || die "dependency SHA-256 mismatch: $filename"
  [[ $(sha256_file "$signature") == "$signature_sha" ]] || die "dependency signature SHA-256 mismatch: $filename"
  dependency_count=$((dependency_count + 1))
done < "$LOCK"
[[ $dependency_count -eq 171 ]] || die "dependency count differs: $dependency_count"
[[ $(find "$DEPENDENCY_DIR" -maxdepth 1 -type f -name '*.pkg.tar.xz' | wc -l | tr -d ' ') -eq 171 ]] || die 'dependency directory contains a different payload count'
[[ $(find "$DEPENDENCY_DIR" -maxdepth 1 -type f -name '*.pkg.tar.xz.sig' | wc -l | tr -d ' ') -eq 171 ]] || die 'dependency directory contains a different signature count'
printf '[PASS] dependency closure packages=171 bytes=230491916 lock=%s\n' "$(sha256_file "$LOCK")"
printf '[PASS] builder            %s\n' "$IMAGE"

if [[ "$ACTION" == check ]]; then
  printf 'Input check complete; Docker was not invoked.\n'
  exit 0
fi

[[ -n "$OUTPUT" ]] || die '--output is required for a build'
[[ ! -e "$OUTPUT" ]] || die "refusing existing output path: $OUTPUT"
case "$OUTPUT" in /|/dev|/dev/*) die "unsafe output path: $OUTPUT" ;; esac
OUTPUT_PARENT=${OUTPUT%/*}
[[ "$OUTPUT_PARENT" != "$OUTPUT" ]] || OUTPUT_PARENT=.
[[ -d "$OUTPUT_PARENT" && -w "$OUTPUT_PARENT" ]] || die "output parent is not writable: $OUTPUT_PARENT"
command -v docker >/dev/null 2>&1 || die 'docker is required for the isolated build'

STAGING="${OUTPUT}.partial.$$"
[[ ! -e "$STAGING" ]] || die "staging path already exists: $STAGING"
mkdir "$STAGING" || die "unable to create staging directory: $STAGING"
docker run --rm --platform linux/arm64 --network none \
  --mount "type=bind,source=$REPO_ROOT/packaging/omarchy-core,target=/recipes,readonly" \
  --mount "type=bind,source=$SOURCE_DIR,target=/sources,readonly" \
  --mount "type=bind,source=$DEPENDENCY_DIR,target=/dependencies,readonly" \
  --mount "type=bind,source=$LOCK,target=/transaction.lock,readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/build-omarchy-core-packages-inside.sh,target=/runner.sh,readonly" \
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
