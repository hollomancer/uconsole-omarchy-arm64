#!/usr/bin/env bash

# Runs only inside the pinned aarch64 Arch Linux ARM build container. Network is
# unnecessary: the source archive and exact kernel headers are mounted read-only.

set -euo pipefail

: "${HEADER_NAME:?}"
: "${SOURCE_ARCHIVE_NAME:?}"
: "${SOURCE_DATE_EPOCH:?}"

tar -xf "/input/${HEADER_NAME}" -C /
KERNEL_RELEASE='6.18.45-1-rpi-16k'
DTC="/usr/lib/modules/${KERNEL_RELEASE}/build/scripts/dtc/dtc"
[[ -x "$DTC" ]] || { printf 'Missing executable dtc: %s\n' "$DTC" >&2; exit 1; }
install -Dm0755 "$DTC" /usr/local/bin/dtc

useradd --create-home builder
install -d -o builder -g builder /work/package /work/sources /output
cp -R /package/. /work/package/
cp "/input/${SOURCE_ARCHIVE_NAME}" "/work/sources/uconsole-cm5-dkms-bf7a0ab55654c96b74d013520e1196d39f66391a.tar.gz"
chown -R builder:builder /work/package /work/sources /output

cd /work/package
runuser -u builder -- env \
  HOME=/home/builder \
  SRCDEST=/work/sources \
  PKGDEST=/output \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  makepkg --cleanbuild --nodeps --noconfirm

PACKAGE=$(find /output -maxdepth 1 -type f -name 'uconsole-cm5-dkms-*.pkg.tar.*' -print)
[[ -n "$PACKAGE" ]] || { printf 'Package artifact not found\n' >&2; exit 1; }
sha256sum "$PACKAGE" > /output/SHA256SUMS
bsdtar -xOf "$PACKAGE" .PKGINFO > /output/PKGINFO
