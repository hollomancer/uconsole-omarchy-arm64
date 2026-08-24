#!/usr/bin/env bash

# Apply the exact shell runtime to an existing disposable Hyprland volume. The
# in-place flag is mandatory because Docker storage may not have room for a
# second full root clone.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

VOLUME=''
PACKAGE_DIR=''
USERLAND_PACKAGE=''
APPLY_IN_PLACE=0
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/test-omarchy-shell-integration.sh --volume V --package-dir DIR' \
    '  --userland-package FILE --apply-in-place' \
    '' \
    'The named volume must be a disposable exact Hyprland integration root.' \
    'The runner snapshots and rechecks boot/hardware/base/Hyprland state.'
}

while (($# > 0)); do
  case "$1" in
    --volume) (($# >= 2)) || { printf 'ERROR: --volume requires a name\n' >&2; exit 2; }; VOLUME=$2; shift 2 ;;
    --package-dir) (($# >= 2)) || { printf 'ERROR: --package-dir requires a directory\n' >&2; exit 2; }; PACKAGE_DIR=$2; shift 2 ;;
    --userland-package) (($# >= 2)) || { printf 'ERROR: --userland-package requires a file\n' >&2; exit 2; }; USERLAND_PACKAGE=$2; shift 2 ;;
    --apply-in-place) APPLY_IN_PLACE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || { printf 'ERROR: unsafe or missing uConsole volume name\n' >&2; exit 2; }
[[ $APPLY_IN_PLACE -eq 1 ]] || { printf 'ERROR: --apply-in-place is required for the named disposable volume\n' >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { printf 'ERROR: Docker volume does not exist: %s\n' "$VOLUME" >&2; exit 2; }
[[ -d "$PACKAGE_DIR" && ! -L "$PACKAGE_DIR" ]] || { printf 'ERROR: package directory is missing or a symlink\n' >&2; exit 2; }
PACKAGE_DIR=$(cd -- "$PACKAGE_DIR" && pwd -P) || { printf 'ERROR: cannot resolve package directory\n' >&2; exit 2; }
[[ -f "$USERLAND_PACKAGE" && ! -L "$USERLAND_PACKAGE" ]] || { printf 'ERROR: userland package is missing or a symlink\n' >&2; exit 2; }
USERLAND_DIR=$(cd -- "$(dirname -- "$USERLAND_PACKAGE")" && pwd -P) || { printf 'ERROR: cannot resolve userland package directory\n' >&2; exit 2; }
USERLAND_PACKAGE="$USERLAND_DIR/${USERLAND_PACKAGE##*/}"
USERLAND_FILENAME=${USERLAND_PACKAGE##*/}
if [[ -e "$PACKAGE_DIR/transaction.lock" ]]; then
  cmp -s "$PACKAGE_DIR/transaction.lock" "$REPO_ROOT/config/omarchy-shell/transaction.lock" || { printf 'ERROR: package cache transaction lock differs\n' >&2; exit 2; }
fi
command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; exit 2; }

docker run --rm --privileged --platform linux/arm64 --network none \
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly" \
  --mount "type=bind,src=$PACKAGE_DIR,dst=/packages,readonly" \
  --mount "type=bind,src=$USERLAND_PACKAGE,dst=/userland/$USERLAND_FILENAME,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/target" \
  "$IMAGE" \
  /repo/research/container/test-omarchy-shell-integration-inside.sh
