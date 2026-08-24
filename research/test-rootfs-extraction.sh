#!/usr/bin/env bash

# Host-side entry point for the real signed rootfs extraction test. It requires
# a new, empty Docker volume and leaves the extracted root available there.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve research directory\n' >&2
  exit 2
fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

VOLUME=''
ROOTFS=/private/tmp/ArchLinuxARM-2026.08-rpi-aarch64-rootfs.tar.gz
SIGNATURE=/private/tmp/ArchLinuxARM-2026.08-rpi-aarch64-rootfs.tar.gz.sig
KEYRING=/private/tmp/archlinuxarm-keyring-20240419-2-any.pkg.tar.xz
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/test-rootfs-extraction.sh --volume EXISTING_EMPTY_VOLUME [options]' \
    '' \
    'Options:' \
    '  --rootfs FILE     Pinned Arch Linux ARM rootfs archive' \
    '  --signature FILE  Pinned detached signature' \
    '  --keyring FILE    Pinned archlinuxarm-keyring package' \
    '  --help            Show this help' \
    '' \
    'The volume is neither created nor deleted by this script.'
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || { printf 'ERROR: --volume requires a name\n' >&2; exit 2; }; VOLUME=$2; shift 2 ;;
    --rootfs) (($# >= 2)) || { printf 'ERROR: --rootfs requires a file\n' >&2; exit 2; }; ROOTFS=$2; shift 2 ;;
    --signature) (($# >= 2)) || { printf 'ERROR: --signature requires a file\n' >&2; exit 2; }; SIGNATURE=$2; shift 2 ;;
    --keyring) (($# >= 2)) || { printf 'ERROR: --keyring requires a file\n' >&2; exit 2; }; KEYRING=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: volume name must begin with uconsole- and use a safe character set\n' >&2; exit 2; }
for input_file in "$ROOTFS" "$SIGNATURE" "$KEYRING"; do
  [[ -f "$input_file" && ! -L "$input_file" ]] || { printf 'ERROR: input is missing or a symlink: %s\n' "$input_file" >&2; exit 2; }
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}
[[ $(sha256_file "$ROOTFS") == f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967 ]] || { printf 'ERROR: rootfs SHA-256 mismatch\n' >&2; exit 2; }
[[ $(sha256_file "$SIGNATURE") == 4465948c272ef9d87e475032be6a107d08b0110053f64ff8c505b7b92c69ab4d ]] || { printf 'ERROR: signature SHA-256 mismatch\n' >&2; exit 2; }
[[ $(sha256_file "$KEYRING") == 3cb36869edfe413672a6e932cc55d7f8386e1a9d3b38663cfb3bc6fe0d146e21 ]] || { printf 'ERROR: keyring package SHA-256 mismatch\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$VOLUME" >&2; exit 2; }

docker run --rm --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$ROOTFS,dst=/input/ArchLinuxARM-rootfs.tar.gz,readonly" \
  --mount "type=bind,src=$SIGNATURE,dst=/input/ArchLinuxARM-rootfs.tar.gz.sig,readonly" \
  --mount "type=bind,src=$KEYRING,dst=/input/archlinuxarm-keyring.pkg.tar.xz,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/test-rootfs-extraction-inside.sh
