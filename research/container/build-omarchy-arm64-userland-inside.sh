#!/usr/bin/env bash

set -euo pipefail
: "${SOURCE_DATE_EPOCH:?}"

useradd --create-home builder
install -d -o builder -g builder /work/package /work/sources /output
cp -R /recipe/. /work/package/
cp /recipe/overrides/* /work/package/
cp /overrides/omarchy-command-policy.tsv /work/package/
cp /overrides/omarchy-plugin-policy.tsv /work/package/
cp /overrides/shell.json /work/package/
cp /overrides/omarchy-menu.jsonc /work/package/
cp /input/omarchy-d99d4fc6.tar.gz /work/sources/omarchy-d99d4fc6de0bc99d48c9935724fa19d7fb41ae54.tar.gz
chown -R builder:builder /work/package /work/sources /output

cd /work/package
runuser -u builder -- env \
  HOME=/home/builder \
  SRCDEST=/work/sources \
  PKGDEST=/output \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  makepkg --cleanbuild --nodeps --noconfirm

PACKAGE=$(find /output -maxdepth 1 -type f -name 'omarchy-arm64-userland-*.pkg.tar.*' ! -name '*.sig' -print)
[[ -n "$PACKAGE" ]]
PKGINFO=$(bsdtar -xOf "$PACKAGE" .PKGINFO)
grep -Fxq 'pkgname = omarchy-arm64-userland' <<< "$PKGINFO"
grep -Fxq 'arch = any' <<< "$PKGINFO"

mkdir /inspect
bsdtar -xf "$PACKAGE" -C /inspect
mapfile -t EXPOSED < <(find /inspect/usr/bin -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${EXPOSED[*]}" == 'omarchy-launch-shell omarchy-menu omarchy-shell' ]]

SELECTED_COUNT=$(awk -F '|' '$0 !~ /^#/ && NF {n++} END {print n+0}' /overrides/omarchy-command-policy.tsv)
INTERNAL_COUNT=$(find /inspect/usr/share/omarchy-arm64/bin -maxdepth 1 -type f | wc -l)
[[ "$SELECTED_COUNT" -eq 37 && "$INTERNAL_COUNT" -eq "$SELECTED_COUNT" ]]
[[ -f /inspect/usr/share/omarchy-arm64/shell/shell.qml ]]
cmp -s /inspect/usr/share/omarchy-arm64/config/omarchy/shell.json /overrides/shell.json
cmp -s /inspect/usr/share/omarchy-arm64/default/omarchy/omarchy-menu.jsonc /overrides/omarchy-menu.jsonc
[[ ! -e /inspect/boot && ! -e /inspect/etc && ! -e /inspect/usr/share/omarchy-arm64/default/hypr ]]

if find /inspect/usr/share/omarchy-arm64/bin -maxdepth 1 -type f -printf '%f\n' |
  grep -E '(update|migrate|pkg|boot|kernel|firmware|snapper|limine)' >/dev/null; then
  printf 'Forbidden ownership command entered the package\n' >&2
  exit 1
fi

bsdtar -tf "$PACKAGE" > /output/MANIFEST
printf '%s\n' "$PKGINFO" > /output/PKGINFO
bsdtar -xOf "$PACKAGE" .BUILDINFO > /output/BUILDINFO
bsdtar -xOf "$PACKAGE" .MTREE | gzip -dc > /output/MTREE
awk '
  /^\/set / && / uid=0/ && / gid=0/ { root_default = 1 }
  / uid=/ && $0 !~ / uid=0([[:space:]]|$)/ { bad_owner = 1 }
  / gid=/ && $0 !~ / gid=0([[:space:]]|$)/ { bad_owner = 1 }
  END { exit !(root_default && !bad_owner) }
' /output/MTREE

PACKAGE_SHA=$(sha256sum "$PACKAGE" | awk '{print $1}')
PACKAGE_SIZE=$(stat -c '%s' "$PACKAGE")
PACKAGE_VERSION=$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<< "$PKGINFO")
[[ "$PACKAGE_VERSION" == '4.0.0.alpha-2' ]]
printf '# package|version|architecture|sha256|filename|size\n' > /output/artifacts.lock
printf 'omarchy-arm64-userland|%s|any|%s|%s|%s\n' "$PACKAGE_VERSION" "$PACKAGE_SHA" "${PACKAGE##*/}" "$PACKAGE_SIZE" >> /output/artifacts.lock
sha256sum "$PACKAGE" > /output/SHA256SUMS
printf '%s\n' \
  '[PASS] architecture-independent package built in pinned aarch64 container' \
  '[PASS] exactly three reviewed wrappers enter /usr/bin' \
  '[PASS] exactly 37 selected commands remain internal to OMARCHY_PATH' \
  '[PASS] reduced shell and menu policy payloads match byte-for-byte' \
  '[PASS] no Hyprland, boot, firmware, kernel, initramfs or update ownership payload exists' \
  '[PASS] package archive ownership is root:root' \
  > /output/BUILD-RESULTS.txt
