#!/usr/bin/env bash

# Recreate the exact offline Hyprland package cache from frozen official
# databases and the configured Phase 1 package database. No package is installed.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

SOURCE_VOLUME=''
OUTPUT_DIR=''
CORE_DB=/private/tmp/uconsole-image-core.db
EXTRA_DB=/private/tmp/uconsole-image-extra.db
CORE_SHA=e1dc3339e7b9baf3a715509837aff8e73495cfba2d04833ee41525892b3c1b96
EXTRA_SHA=2a587fefde8735bbe6c0c5cb7304a2b666268ec947a33743e30d2c8517684964
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/resolve-hyprland-closure.sh --source-volume V --output-dir NEW_EMPTY_DIR [options]' \
    '' \
    'Options:' \
    '  --core-db FILE     Frozen Arch Linux ARM core database' \
    '  --extra-db FILE    Frozen Arch Linux ARM extra database' \
    '  --help             Show this help' \
    '' \
    'The source volume is mounted read-only. Exact packages and signatures are' \
    'downloaded into temporary storage, verified, compared with the committed' \
    'transaction lock, then copied into the still-empty output directory.'
}

while (($# > 0)); do
  case "$1" in
    --source-volume) (($# >= 2)) || { printf 'ERROR: --source-volume requires a name\n' >&2; exit 2; }; SOURCE_VOLUME=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || { printf 'ERROR: --output-dir requires a directory\n' >&2; exit 2; }; OUTPUT_DIR=$2; shift 2 ;;
    --core-db) (($# >= 2)) || { printf 'ERROR: --core-db requires a file\n' >&2; exit 2; }; CORE_DB=$2; shift 2 ;;
    --extra-db) (($# >= 2)) || { printf 'ERROR: --extra-db requires a file\n' >&2; exit 2; }; EXTRA_DB=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$SOURCE_VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uconsole source volume\n' >&2; exit 2; }
docker volume inspect "$SOURCE_VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$SOURCE_VOLUME" >&2; exit 2; }
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || { printf 'ERROR: output must be an existing real directory\n' >&2; exit 2; }
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P) || { printf 'ERROR: cannot resolve output directory\n' >&2; exit 2; }
[[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || { printf 'ERROR: output directory must be empty\n' >&2; exit 2; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}
for database in "$CORE_DB" "$EXTRA_DB"; do
  [[ -f "$database" && ! -L "$database" ]] || { printf 'ERROR: frozen database is missing or unsafe: %s\n' "$database" >&2; exit 2; }
done
[[ $(sha256_file "$CORE_DB") == "$CORE_SHA" ]] || { printf 'ERROR: frozen core database SHA-256 mismatch\n' >&2; exit 2; }
[[ $(sha256_file "$EXTRA_DB") == "$EXTRA_SHA" ]] || { printf 'ERROR: frozen extra database SHA-256 mismatch\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$CORE_DB,dst=/snapshot/core.db,readonly" \
  --mount "type=bind,src=$EXTRA_DB,dst=/snapshot/extra.db,readonly" \
  --mount "type=bind,src=$OUTPUT_DIR,dst=/output" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/target,readonly" \
  --tmpfs /work:rw,size=1024m \
  "$IMAGE" \
  /repo/research/container/resolve-hyprland-closure-inside.sh
