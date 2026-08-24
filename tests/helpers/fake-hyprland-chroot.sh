#!/usr/bin/env bash

# Deterministic arch-chroot stand-in used only by Hyprland installer fixtures.

set -u
set -o pipefail

ROOT=$1
shift
COMMAND=$1
shift
LOG=${FAKE_CHROOT_LOG:?}
LOCK=${FAKE_HYPRLAND_LOCK:?}
TRANSACTION_LOCK=${FAKE_HYPRLAND_TRANSACTION_LOCK:?}
DATABASE="$ROOT/var/lib/fake-hyprland-packages"

printf '%s' "$COMMAND" >> "$LOG"
printf ' %s' "$@" >> "$LOG"
printf '\n' >> "$LOG"

lock_field() {
  local name=$1
  local field=$2
  awk -F '|' -v wanted="$name" -v field_index="$field" '$0 !~ /^#/ && $1 == wanted { print $field_index; exit }' "$LOCK"
}

[[ "$COMMAND" == 'pacman' ]] || { printf 'Unexpected fake command: %s\n' "$COMMAND" >&2; exit 91; }

if [[ "$1" == '--color' ]]; then
  [[ "$2" == 'never' ]] || { printf 'Unexpected pacman color value\n' >&2; exit 90; }
  shift 2
fi

OPERATION=$1
shift
case "$OPERATION" in
  -Si)
    NAME=$1
    VERSION=$(lock_field "$NAME" 2)
    ARCHITECTURE=$(lock_field "$NAME" 3)
    REPOSITORY=$(lock_field "$NAME" 4)
    [[ -n "$VERSION" && -n "$ARCHITECTURE" && -n "$REPOSITORY" ]] || exit 1
    printf 'Repository      : %s\n' "$REPOSITORY"
    printf 'Name            : %s\n' "$NAME"
    printf 'Version         : %s\n' "$VERSION"
    printf 'Architecture    : %s\n' "$ARCHITECTURE"
    ;;
  -Q)
    NAME=$1
    [[ -f "$DATABASE" ]] || exit 1
    awk -v wanted="$NAME" '$1 == wanted { print; found=1 } END { exit !found }' "$DATABASE"
    ;;
  -S)
    touch "$DATABASE"
    for argument in "$@"; do
      case "$argument" in --*) continue ;; esac
      VERSION=$(lock_field "$argument" 2)
      [[ -n "$VERSION" ]] || { printf 'Unknown fake package: %s\n' "$argument" >&2; exit 90; }
      awk -v unwanted="$argument" '$1 != unwanted' "$DATABASE" > "$DATABASE.next"
      printf '%s %s\n' "$argument" "$VERSION" >> "$DATABASE.next"
      mv "$DATABASE.next" "$DATABASE"
    done
    ;;
  -U)
    touch "$DATABASE"
    for argument in "$@"; do
      case "$argument" in --*) continue ;; esac
      FILENAME=${argument##*/}
      PACKAGE_ROW=$(awk -F '|' -v wanted="$FILENAME" '$0 !~ /^#/ && $8 == wanted { count++; row=$0 } END { if (count == 1) print row; else exit 1 }' "$TRANSACTION_LOCK") || { printf 'Unknown fake transaction package: %s\n' "$FILENAME" >&2; exit 90; }
      NAME=${PACKAGE_ROW%%|*}
      REMAINDER=${PACKAGE_ROW#*|}
      VERSION=${REMAINDER%%|*}
      awk -v unwanted="$NAME" '$1 != unwanted' "$DATABASE" > "$DATABASE.next"
      printf '%s %s\n' "$NAME" "$VERSION" >> "$DATABASE.next"
      mv "$DATABASE.next" "$DATABASE"
    done
    ;;
  *)
    printf 'Unexpected fake pacman operation: %s\n' "$OPERATION" >&2
    exit 90
    ;;
esac
