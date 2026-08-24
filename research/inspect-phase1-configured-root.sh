#!/usr/bin/env bash

# Read-only inspection of the configured Phase 1 root. This runs the regular
# image builder's full plan gate but never creates an image.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

VOLUME=''
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/inspect-phase1-configured-root.sh --volume EXISTING_ROOT_VOLUME' \
    '' \
    'The retained root is mounted read-only and no image or device is opened.'
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || { printf 'ERROR: --volume requires a name\n' >&2; exit 2; }; VOLUME=$2; shift 2 ;;
    --apply|--configure|--build|--build-image|--device|--write-device|--publish)
      printf 'ERROR: mutating arguments are forbidden: %s\n' "$1" >&2
      exit 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-phase1-operator-pending-[0-9]{8}$ ]] || { printf 'ERROR: unsafe or missing Phase 1 volume name\n' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$VOLUME" >&2; exit 2; }
CONTAINER_REFERENCES=$(docker ps -aq --filter "volume=$VOLUME") || { printf 'ERROR: unable to inspect volume references\n' >&2; exit 2; }
[[ -z "$CONTAINER_REFERENCES" ]] || { printf 'ERROR: target volume is referenced by a container\n' >&2; exit 2; }

docker run --rm --read-only --log-driver none --privileged --platform linux/arm64 --network none \
  --tmpfs /run:rw,nosuid,nodev \
  --tmpfs /source/root/run:rw,nosuid,nodev \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/source,readonly" \
  "$IMAGE" \
  /repo/research/container/inspect-phase1-configured-root-inside.sh
