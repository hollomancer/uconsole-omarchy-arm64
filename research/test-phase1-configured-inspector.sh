#!/usr/bin/env bash

# Restore the verified private synthetic base-system archive into a sparse ext4
# image on external storage, inspect that filesystem read-only, then remove only
# the directory created by this runner.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

ARCHIVE_DIRECTORY=''
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'
SOURCE_VOLUME=uconsole-base-system-integration-20260824
WORKSPACE=''
WORKSPACE_CREATED=0

usage() {
  printf '%s\n' \
    'Usage: research/test-phase1-configured-inspector.sh --archive-directory DIR' \
    '' \
    'The verified private base-system archive is mounted read-only. A disposable' \
    'directory is created beside it, inspected read-only, and removed afterward.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

cleanup_workspace() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $WORKSPACE_CREATED -eq 1 ]]; then
    case "$WORKSPACE" in
      /Volumes/*/uconsole-phase1-configured-inspection-20260824)
        rm -rf -- "$WORKSPACE" || status=1
        ;;
      *)
        printf 'ERROR: refusing unsafe configured-inspection cleanup: %s\n' "$WORKSPACE" >&2
        status=1
        ;;
    esac
  fi
  exit "$status"
}
trap cleanup_workspace EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --archive-directory) (($# >= 2)) || die '--archive-directory requires a path'; ARCHIVE_DIRECTORY=$2; shift 2 ;;
    --retain-workspace|--remove-archive|--delete-source|--publish|--device) die "$1 is forbidden" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -d "$ARCHIVE_DIRECTORY" && ! -L "$ARCHIVE_DIRECTORY" && "$ARCHIVE_DIRECTORY" != *,* ]] || die 'archive directory is missing or unsafe'
ARCHIVE_DIRECTORY=$(cd -- "$ARCHIVE_DIRECTORY" && pwd -P) || die 'unable to resolve archive directory'
[[ "$ARCHIVE_DIRECTORY" =~ ^/Volumes/[^/]+/uconsole-omarchy-arm64-volume-archives-[0-9]{8}$ ]] || die 'archive directory is outside the private external namespace'
for archive_input in "$ARCHIVE_DIRECTORY/${SOURCE_VOLUME}.tar" "$ARCHIVE_DIRECTORY/${SOURCE_VOLUME}.archive.json"; do
  [[ -f "$archive_input" && ! -L "$archive_input" ]] || die "archive input is missing or unsafe: $archive_input"
done
WORKSPACE_PARENT=${ARCHIVE_DIRECTORY%/*}
WORKSPACE="$WORKSPACE_PARENT/uconsole-phase1-configured-inspection-20260824"
[[ ! -e "$WORKSPACE" && ! -L "$WORKSPACE" ]] || die 'disposable configured-inspection directory already exists'
mkdir -m 0700 "$WORKSPACE" || die 'unable to create disposable configured-inspection directory'
WORKSPACE_CREATED=1

docker run --rm --read-only --log-driver none --platform linux/arm64 --network none \
  --privileged \
  --tmpfs /run:rw,nosuid,nodev \
  --tmpfs /restore:rw,nosuid,nodev \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$ARCHIVE_DIRECTORY,dst=/archive,readonly" \
  --mount "type=bind,src=$WORKSPACE,dst=/work" \
  "$IMAGE" \
  /repo/research/container/test-phase1-configured-inspector-inside.sh || die 'private configured-root integration failed'

printf '[PASS] configured inspector integration completed from the private verified archive\n'
printf '[PASS] cleanup boundary will remove only %s\n' "$WORKSPACE"
