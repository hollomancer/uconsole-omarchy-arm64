#!/usr/bin/env bash

# Deterministic arch-chroot stand-in used only by installer fixture tests.

set -u
set -o pipefail

ROOT=$1
shift
COMMAND=$1
shift
LOG=${FAKE_CHROOT_LOG:?}
DATABASE="$ROOT/var/lib/fake-packages"

printf '%s' "$COMMAND" >> "$LOG"
printf ' %s' "$@" >> "$LOG"
printf '\n' >> "$LOG"

if [[ "$COMMAND" == 'pacman' ]]; then
  OPERATION=$1
  shift
  case "$OPERATION" in
    -T)
      exit 0
      ;;
    -Q)
      NAME=$1
      awk -v wanted="$NAME" '$1 == wanted { print; found=1 } END { exit !found }' "$DATABASE"
      ;;
    -Rdd)
      exit 0
      ;;
    -U)
      : > "$DATABASE"
      for argument in "$@"; do
        case "$argument" in
          --*) continue ;;
        esac
        PACKAGE="$ROOT$argument"
        PKGINFO=$(bsdtar -xOf "$PACKAGE" .PKGINFO)
        NAME=$(printf '%s\n' "$PKGINFO" | awk -F ' = ' '$1 == "pkgname" { print $2; exit }')
        VERSION=$(printf '%s\n' "$PKGINFO" | awk -F ' = ' '$1 == "pkgver" { print $2; exit }')
        printf '%s %s\n' "$NAME" "$VERSION" >> "$DATABASE"
      done
      mkdir -p "$ROOT/boot/overlays" "$ROOT/usr/src/uconsole-cm5-0.1"
      printf 'fixture base overlay\n' > "$ROOT/boot/overlays/uconsole-cm5-base.dtbo"
      printf 'fixture audio overlay\n' > "$ROOT/boot/overlays/uconsole-audio-cm5.dtbo"
      printf 'PACKAGE_NAME="uconsole-cm5"\n' > "$ROOT/usr/src/uconsole-cm5-0.1/dkms.conf"
      ;;
    *)
      printf 'Unexpected fake pacman operation: %s\n' "$OPERATION" >&2
      exit 90
      ;;
  esac
elif [[ "$COMMAND" == 'dkms' && "$1" == 'status' ]]; then
  printf 'uconsole-cm5/0.1, fixture-rpi-16k, aarch64: installed\n'
else
  printf 'Unexpected fake chroot command: %s %s\n' "$COMMAND" "$*" >&2
  exit 91
fi

