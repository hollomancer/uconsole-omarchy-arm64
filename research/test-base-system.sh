#!/usr/bin/env bash

# Host entry point for native-aarch64 base-system integration. Both named
# volumes must already exist; the destination must be empty and is retained.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

SOURCE_VOLUME=''
DESTINATION_VOLUME=''
INPUT_DIR=/private/tmp
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/test-base-system.sh --source-volume V --destination-volume V [options]' \
    '' \
    'Options:' \
    '  --input-dir DIR   Directory containing exact locked packages' \
    '  --help            Show this help' \
    '' \
    'The source is mounted read-only. The destination is neither created nor' \
    'deleted and must be empty.'
}

while (($# > 0)); do
  case "$1" in
    --source-volume) (($# >= 2)) || { printf 'ERROR: --source-volume requires a name\n' >&2; exit 2; }; SOURCE_VOLUME=$2; shift 2 ;;
    --destination-volume) (($# >= 2)) || { printf 'ERROR: --destination-volume requires a name\n' >&2; exit 2; }; DESTINATION_VOLUME=$2; shift 2 ;;
    --input-dir) (($# >= 2)) || { printf 'ERROR: --input-dir requires a directory\n' >&2; exit 2; }; INPUT_DIR=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for volume in "$SOURCE_VOLUME" "$DESTINATION_VOLUME"; do
  [[ "$volume" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uconsole volume name\n' >&2; exit 2; }
  docker volume inspect "$volume" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$volume" >&2; exit 2; }
done
[[ "$SOURCE_VOLUME" != "$DESTINATION_VOLUME" ]] || { printf 'ERROR: source and destination volumes must differ\n' >&2; exit 2; }
[[ -d "$INPUT_DIR" && ! -L "$INPUT_DIR" ]] || { printf 'ERROR: input directory is missing or a symlink\n' >&2; exit 2; }
INPUT_DIR=$(cd -- "$INPUT_DIR" && pwd -P) || { printf 'ERROR: cannot resolve input directory\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$INPUT_DIR,dst=/input,readonly" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "type=volume,src=$DESTINATION_VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/test-base-system-inside.sh
