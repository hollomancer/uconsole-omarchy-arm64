#!/usr/bin/env bash

# Exercise conflict-safe Omarchy home preparation in the retained disposable
# native ARM64 shell root. The in-place flag is mandatory.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

VOLUME=''
SOURCE_ARCHIVE=''
APPLY_IN_PLACE=0
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/test-omarchy-user-preparation-integration.sh --volume V' \
    '  --source-archive FILE --apply-in-place'
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || { printf 'ERROR: --volume requires a name\n' >&2; exit 2; }; VOLUME=$2; shift 2 ;;
    --source-archive) (($# >= 2)) || { printf 'ERROR: --source-archive requires a file\n' >&2; exit 2; }; SOURCE_ARCHIVE=$2; shift 2 ;;
    --apply-in-place) APPLY_IN_PLACE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uConsole volume name\n' >&2; exit 2; }
[[ $APPLY_IN_PLACE -eq 1 ]] || { printf 'ERROR: --apply-in-place is required\n' >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$VOLUME" >&2; exit 2; }
[[ -f "$SOURCE_ARCHIVE" && ! -L "$SOURCE_ARCHIVE" ]] || { printf 'ERROR: source archive is missing or a symlink\n' >&2; exit 2; }
SOURCE_DIR=$(cd -- "$(dirname -- "$SOURCE_ARCHIVE")" && pwd -P) || { printf 'ERROR: cannot resolve source archive directory\n' >&2; exit 2; }
SOURCE_ARCHIVE="$SOURCE_DIR/${SOURCE_ARCHIVE##*/}"
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 --network none \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$SOURCE_ARCHIVE,dst=/source/omarchy.tar.gz,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/target" \
  "$IMAGE" \
  /repo/research/container/test-omarchy-user-preparation-integration-inside.sh
