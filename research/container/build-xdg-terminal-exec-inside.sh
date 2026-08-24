#!/usr/bin/env bash

# Runs only inside the pinned aarch64 Arch Linux ARM build container. All
# source, build dependency and test dependency payloads are mounted read-only.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:?}"

pacman -U --noconfirm \
  /input/scdoc-1.11.5-1-aarch64.pkg.tar.xz \
  /input/parallel-20260722-1-any.pkg.tar.xz \
  /input/bats-1.14.0-1-any.pkg.tar.xz

useradd --create-home builder
install -d -o builder -g builder /work/package /work/sources /output
cp -R /package/. /work/package/
cp /input/xdg-terminal-exec-v0.14.3.tar.gz /work/sources/
chown -R builder:builder /work/package /work/sources /output

cd /work/package
runuser -u builder -- env \
  HOME=/home/builder \
  SRCDEST=/work/sources \
  PKGDEST=/output \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  makepkg --cleanbuild --nodeps --noconfirm

PACKAGE=$(find /output -maxdepth 1 -type f -name 'xdg-terminal-exec-*.pkg.tar.*' -print)
[[ -n "$PACKAGE" ]] || { printf 'Package artifact not found\n' >&2; exit 1; }
sha256sum "$PACKAGE" > /output/SHA256SUMS
bsdtar -xOf "$PACKAGE" .PKGINFO > /output/PKGINFO
