#!/usr/bin/env bash

# Install and remove the built package in a disposable aarch64 root. The target
# is created inside the container; neither the host nor a development SD card is
# writable from this test.

set -u
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
PACKAGE=''
ACTION='run'
EXPECTED_SHA256='19cd7f72f025562110c3750224561534a9994ac9ec4bb9849b3b6da01c1039aa'
EXPECTED_SIZE='65321824'
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
file_size() { if stat -f '%z' "$1" >/dev/null 2>&1; then stat -f '%z' "$1"; else stat -c '%s' "$1"; fi; }

while (($# > 0)); do
  case "$1" in
    --package) (($# >= 2)) || die '--package requires a file'; PACKAGE=$2; shift 2 ;;
    --check) ACTION='check'; shift ;;
    --help|-h) printf 'Usage: test-omarchy-arm64-userland-install.sh --package FILE [--check]\n'; exit 0 ;;
    --root|--device|--apply|--activate) die "$1 is unsupported; the test root is container-internal" ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$PACKAGE" && ! -L "$PACKAGE" ]] || die 'package must be a regular, non-symlink file'
[[ "${PACKAGE##*/}" == 'omarchy-arm64-userland-4.0.0.alpha-2-any.pkg.tar.xz' ]] || die 'unexpected package filename'
[[ "$(sha256_file "$PACKAGE")" == "$EXPECTED_SHA256" ]] || die 'package SHA-256 mismatch'
[[ "$(file_size "$PACKAGE")" == "$EXPECTED_SIZE" ]] || die 'package size mismatch'
printf '[PASS] package sha256=%s bytes=%s\n' "$EXPECTED_SHA256" "$EXPECTED_SIZE"
printf '[PASS] builder %s\n' "$IMAGE"
[[ "$ACTION" == 'run' ]] || { printf 'Input check complete; Docker was not invoked.\n'; exit 0; }

command -v docker >/dev/null 2>&1 || die 'docker is required'
PACKAGE_NAME=${PACKAGE##*/}
PACKAGE_DIR=$(dirname -- "$PACKAGE") || die 'unable to resolve package parent'
PACKAGE=$(cd -- "$PACKAGE_DIR" && printf '%s/%s\n' "$PWD" "$PACKAGE_NAME") || die 'unable to resolve package'
docker run --rm --platform linux/arm64 --network none \
  --mount "type=bind,source=$PACKAGE,target=/input/$PACKAGE_NAME,readonly" \
  --mount "type=bind,source=$SCRIPT_DIR/container/test-omarchy-arm64-userland-install-inside.sh,target=/runner.sh,readonly" \
  --entrypoint /bin/bash \
  "$IMAGE" /runner.sh "/input/$PACKAGE_NAME"
