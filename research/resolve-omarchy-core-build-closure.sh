#!/usr/bin/env bash

# Recreate the exact signed Arch Linux ARM dependency cache used to build the
# five small core Omarchy packages. Nothing is installed on the host or target.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

OUTPUT_DIR=''
CORE_DB=/private/tmp/uconsole-image-core.db
EXTRA_DB=/private/tmp/uconsole-image-extra.db
CORE_SHA=e1dc3339e7b9baf3a715509837aff8e73495cfba2d04833ee41525892b3c1b96
EXTRA_SHA=2a587fefde8735bbe6c0c5cb7304a2b666268ec947a33743e30d2c8517684964
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/resolve-omarchy-core-build-closure.sh --output-dir EMPTY_DIR [options]' \
    '' \
    'Options:' \
    '  --core-db FILE     Frozen Arch Linux ARM core database' \
    '  --extra-db FILE    Frozen Arch Linux ARM extra database' \
    '  --help             Show this help' \
    '' \
    'The output is promoted only after all signatures, hashes, provider choices' \
    'and the complete transaction agree with the committed lock.'
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

while (($# > 0)); do
  case "$1" in
    --output-dir) (($# >= 2)) || die '--output-dir requires a directory'; OUTPUT_DIR=$2; shift 2 ;;
    --core-db) (($# >= 2)) || die '--core-db requires a file'; CORE_DB=$2; shift 2 ;;
    --extra-db) (($# >= 2)) || die '--extra-db requires a file'; EXTRA_DB=$2; shift 2 ;;
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

[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die 'output must be an existing real directory'
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P) || die 'cannot resolve output directory'
[[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'output directory must be empty'
for database in "$CORE_DB" "$EXTRA_DB"; do
  [[ -f "$database" && ! -L "$database" ]] || die "frozen database is missing or unsafe: $database"
done
[[ $(sha256_file "$CORE_DB") == "$CORE_SHA" ]] || die 'frozen core database SHA-256 mismatch'
[[ $(sha256_file "$EXTRA_DB") == "$EXTRA_SHA" ]] || die 'frozen extra database SHA-256 mismatch'
command -v docker >/dev/null 2>&1 || die 'docker is required'

docker run --rm --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$CORE_DB,dst=/snapshot/core.db,readonly" \
  --mount "type=bind,src=$EXTRA_DB,dst=/snapshot/extra.db,readonly" \
  --mount "type=bind,src=$OUTPUT_DIR,dst=/output" \
  --tmpfs /work:rw,size=1024m \
  "$IMAGE" \
  /repo/research/container/resolve-omarchy-core-build-closure-inside.sh
