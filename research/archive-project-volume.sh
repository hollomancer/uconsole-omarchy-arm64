#!/usr/bin/env bash

# Archive or restore-verify one project-owned Docker integration volume. Source
# volumes are always read-only and this script never removes an original.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

ACTION=archive
ACTION_SET=0
VOLUME=''
ARCHIVE_DIRECTORY=''
BUILDER_IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/archive-project-volume.sh --volume NAME --archive-directory DIR [action]' \
    '' \
    'Actions:' \
    '  --archive          Create, list, hash and source-compare a new archive (default)' \
    '  --restore-verify   Extract into a disposable Docker volume, compare and remove it' \
    '' \
    'Original volumes are never removed. Archive and source mounts are read-only' \
    'during restore verification.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

set_action() {
  local requested=$1
  if [[ $ACTION_SET -eq 1 ]]; then die 'choose at most one action'; fi
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || die '--volume requires a name'; VOLUME=$2; shift 2 ;;
    --archive-directory) (($# >= 2)) || die '--archive-directory requires a path'; ARCHIVE_DIRECTORY=$2; shift 2 ;;
    --archive) set_action archive; shift ;;
    --restore-verify) set_action restore; shift ;;
    --remove-source|--delete-volume|--publish|--device) die "$1 is forbidden by the archive boundary" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-(base-system|hyprland)-integration-[0-9]{8}$ ]] || die 'volume is outside the exact project integration namespace'
[[ -d "$ARCHIVE_DIRECTORY" && ! -L "$ARCHIVE_DIRECTORY" ]] || die 'archive directory must already exist and must not be a symlink'
[[ "$ARCHIVE_DIRECTORY" != *,* ]] || die 'archive directory must not contain a comma'
if ! ARCHIVE_DIRECTORY=$(cd -- "$ARCHIVE_DIRECTORY" && pwd -P); then die 'unable to resolve archive directory'; fi
[[ "$ARCHIVE_DIRECTORY" =~ ^/Volumes/[^/]+/uconsole-omarchy-arm64-volume-archives-[0-9]{8}$ ]] || die 'archive directory is outside the external project archive namespace'
command -v docker >/dev/null 2>&1 || die 'docker is required'

ARCHIVE_NAME="${VOLUME}.tar"
MANIFEST_NAME="${VOLUME}.archive.json"
RESTORE_VOLUME="uconsole-archive-restore-check-${VOLUME#uconsole-}"

if [[ "$ACTION" == archive ]]; then
  docker volume inspect "$VOLUME" >/dev/null || die "source volume does not exist: $VOLUME"
  CONTAINER_REFERENCES=$(docker ps -aq --filter "volume=$VOLUME") || die 'unable to inspect source-volume references'
  [[ -z "$CONTAINER_REFERENCES" ]] || die "source volume is referenced by a container: $VOLUME"
  [[ ! -e "$ARCHIVE_DIRECTORY/$ARCHIVE_NAME" && ! -L "$ARCHIVE_DIRECTORY/$ARCHIVE_NAME" ]] || die 'archive output already exists'
  [[ ! -e "$ARCHIVE_DIRECTORY/$MANIFEST_NAME" && ! -L "$ARCHIVE_DIRECTORY/$MANIFEST_NAME" ]] || die 'archive manifest already exists'
  docker run --rm --platform linux/arm64 --network none \
    --env UCONSOLE_ARCHIVE_ACTION=archive \
    --env UCONSOLE_VOLUME_NAME="$VOLUME" \
    --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
    --mount "type=volume,src=$VOLUME,dst=/source,readonly" \
    --mount "type=bind,src=$ARCHIVE_DIRECTORY,dst=/archive" \
    "$BUILDER_IMAGE" \
    /repo/research/container/archive-project-volume-inside.sh
  exit $?
fi

[[ -f "$ARCHIVE_DIRECTORY/$ARCHIVE_NAME" && ! -L "$ARCHIVE_DIRECTORY/$ARCHIVE_NAME" ]] || die 'verified archive is missing or unsafe'
[[ -f "$ARCHIVE_DIRECTORY/$MANIFEST_NAME" && ! -L "$ARCHIVE_DIRECTORY/$MANIFEST_NAME" ]] || die 'verified archive manifest is missing or unsafe'
if docker volume inspect "$RESTORE_VOLUME" >/dev/null 2>&1; then die "disposable restore volume already exists: $RESTORE_VOLUME"; fi
docker volume create "$RESTORE_VOLUME" >/dev/null || die 'unable to create disposable restore volume'
if ! docker run --rm --platform linux/arm64 --network none \
  --env UCONSOLE_ARCHIVE_ACTION=restore \
  --env UCONSOLE_VOLUME_NAME="$VOLUME" \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$ARCHIVE_DIRECTORY,dst=/archive,readonly" \
  --mount "type=volume,src=$RESTORE_VOLUME,dst=/restore" \
  "$BUILDER_IMAGE" \
  /repo/research/container/archive-project-volume-inside.sh; then
  die "restore verification failed; retained disposable volume: $RESTORE_VOLUME"
fi
docker volume rm "$RESTORE_VOLUME" >/dev/null || die "restore passed but disposable volume removal failed: $RESTORE_VOLUME"
printf '[PASS] restore cleanup     verified disposable volume removed: %s\n' "$RESTORE_VOLUME"
