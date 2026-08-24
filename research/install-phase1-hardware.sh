#!/usr/bin/env bash

# Host entry point for applying the selected hardware layer to the retained
# Linux volume. All package bytes are revalidated by the called installers.

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
INPUT_DIR=/private/tmp
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/install-phase1-hardware.sh --volume EXISTING_ROOT_VOLUME [options]' \
    '' \
    'Options:' \
    '  --input-dir DIR   Directory containing the exact locked packages' \
    '  --help            Show this help' \
    '' \
    'The retained volume is modified. No image or physical device is accepted.'
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || { printf 'ERROR: --volume requires a name\n' >&2; exit 2; }; VOLUME=$2; shift 2 ;;
    --input-dir) (($# >= 2)) || { printf 'ERROR: --input-dir requires a directory\n' >&2; exit 2; }; INPUT_DIR=$2; shift 2 ;;
    --device|--write-device) printf 'ERROR: physical-device arguments are forbidden\n' >&2; exit 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uconsole volume name\n' >&2; exit 2; }
[[ -d "$INPUT_DIR" && ! -L "$INPUT_DIR" ]] || { printf 'ERROR: input directory is missing or a symlink\n' >&2; exit 2; }
INPUT_DIR=$(cd -- "$INPUT_DIR" && pwd -P) || { printf 'ERROR: cannot resolve input directory\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$VOLUME" >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$INPUT_DIR,dst=/input,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/install-phase1-hardware-inside.sh
