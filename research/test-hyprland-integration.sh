#!/usr/bin/env bash

# Clone the synthetic configured Phase 1 root, apply the exact offline
# Hyprland transaction, and retain the destination for later Omarchy work.
# The source volume is mounted read-only and neither volume is created or
# deleted by this runner.

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

SOURCE_VOLUME=''
DESTINATION_VOLUME=''
PACKAGE_DIR=''
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/test-hyprland-integration.sh --source-volume V --destination-volume V --package-dir DIR' \
    '' \
    'The source is read-only. The destination must already exist and be empty.' \
    'The package directory must contain the exact committed Hyprland transaction.'
}

while (($# > 0)); do
  case "$1" in
    --source-volume) (($# >= 2)) || { printf 'ERROR: --source-volume requires a name\n' >&2; exit 2; }; SOURCE_VOLUME=$2; shift 2 ;;
    --destination-volume) (($# >= 2)) || { printf 'ERROR: --destination-volume requires a name\n' >&2; exit 2; }; DESTINATION_VOLUME=$2; shift 2 ;;
    --package-dir) (($# >= 2)) || { printf 'ERROR: --package-dir requires a directory\n' >&2; exit 2; }; PACKAGE_DIR=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for volume in "$SOURCE_VOLUME" "$DESTINATION_VOLUME"; do
  [[ "$volume" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uConsole volume name\n' >&2; exit 2; }
  docker volume inspect "$volume" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$volume" >&2; exit 2; }
done
[[ "$SOURCE_VOLUME" != "$DESTINATION_VOLUME" ]] || { printf 'ERROR: source and destination volumes must differ\n' >&2; exit 2; }
[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || { printf 'ERROR: package directory is missing or a symlink\n' >&2; exit 2; }
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || { printf 'ERROR: cannot resolve package directory\n' >&2; exit 2; }
if [[ -e "$PACKAGE_DIR/transaction.lock" ]]; then
  [[ -f "$PACKAGE_DIR/transaction.lock" && ! -L "$PACKAGE_DIR/transaction.lock" ]] || {
    printf 'ERROR: package-directory transaction lock is unsafe\n' >&2
    exit 2
  }
  cmp -s "$PACKAGE_DIR/transaction.lock" "$REPO_ROOT/config/hyprland/transaction.lock" || {
    printf 'ERROR: package-directory transaction lock differs from the repository\n' >&2
    exit 2
  }
fi
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$PACKAGE_DIR,dst=/packages,readonly" \
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/source,readonly" \
  --mount "type=volume,src=$DESTINATION_VOLUME,dst=/output" \
  "$IMAGE" \
  /repo/research/container/test-hyprland-integration-inside.sh
