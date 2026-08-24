#!/usr/bin/env bash

# Runs only inside the pinned aarch64 package builder. Candidate sources,
# recipes and official dependency packages are all mounted read-only.

set -euo pipefail
: "${SOURCE_DATE_EPOCH:?}"

PACKAGES=(ttf-ia-writer omacalc omacut ttfx yaru-icon-theme)
DEPENDENCIES=()
while IFS='|' read -r _ _ _ _ _ _ _ filename _; do
  [[ -n "$filename" && "$filename" != filename ]] || continue
  DEPENDENCIES+=("/dependencies/$filename")
done < /transaction.lock
[[ ${#DEPENDENCIES[@]} -eq 171 ]]

# Pacman validates the detached signatures again before the dependencies enter
# this disposable container. No repository sync or target root is involved.
pacman -U --needed --noconfirm "${DEPENDENCIES[@]}"

useradd --create-home builder
install -d -o builder -g builder /work/sources /work/packages /output
cp /sources/omacalc-0.2.2.tar.gz /work/sources/
cp /sources/omacut-0.4.0.tar.gz /work/sources/
cp /sources/ia-fonts-b337fe1a.tar.gz /work/sources/
cp /sources/ttfx-0.3.2.tar.gz /work/sources/
cp /sources/ttfx-0.3.2-vendor.tar.zst /work/sources/
cp /sources/yaru-26.04.5.1ubuntu.tar.gz /work/sources/
chown -R builder:builder /work /output

for package_name in "${PACKAGES[@]}"; do
  install -d -o builder -g builder "/work/packages/$package_name"
  cp -R "/recipes/$package_name/." "/work/packages/$package_name/"
  chown -R builder:builder "/work/packages/$package_name"
  (
    cd "/work/packages/$package_name"
    runuser -u builder -- env \
      HOME=/home/builder \
      SRCDEST=/work/sources \
      PKGDEST=/output \
      SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
      CARGO_NET_OFFLINE=true \
      QT_QPA_PLATFORM=offscreen \
      MAKEFLAGS=-j2 \
      makepkg --cleanbuild --nodeps --noconfirm
  )
done

mapfile -t ARTIFACTS < <(find /output -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort)
[[ ${#ARTIFACTS[@]} -eq 5 ]] || { printf 'Expected five package artifacts; found %d\n' "${#ARTIFACTS[@]}" >&2; exit 1; }

printf '# package|version|architecture|sha256|filename|size\n' > /output/artifacts.lock
printf '# package|path|file-description\n' > /output/payload-architectures.tsv
mkdir /inspect
for artifact in "${ARTIFACTS[@]}"; do
  pkginfo=$(bsdtar -xOf "$artifact" .PKGINFO)
  package_name=$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgname" { print $2; exit }')
  package_version=$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgver" { print $2; exit }')
  architecture=$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "arch" { print $2; exit }')
  [[ -n "$package_name" && -n "$package_version" && -n "$architecture" ]]
  package_sha=$(sha256sum "$artifact" | awk '{print $1}')
  package_size=$(stat -c '%s' "$artifact")
  filename=${artifact##*/}
  printf '%s|%s|%s|%s|%s|%s\n' "$package_name" "$package_version" "$architecture" "$package_sha" "$filename" "$package_size" >> /output/artifacts.lock
  printf '%s\n' "$pkginfo" > "/output/$package_name.PKGINFO"
  bsdtar -xOf "$artifact" .BUILDINFO > "/output/$package_name.BUILDINFO"
  bsdtar -xOf "$artifact" .MTREE | gzip -dc > "/output/$package_name.MTREE"
  awk '
    /^\/set / && / uid=0/ && / gid=0/ { root_default = 1 }
    / uid=/ && $0 !~ / uid=0([[:space:]]|$)/ { bad_owner = 1 }
    / gid=/ && $0 !~ / gid=0([[:space:]]|$)/ { bad_owner = 1 }
    END { exit !(root_default && !bad_owner) }
  ' "/output/$package_name.MTREE" || {
    printf 'Package archive has unsafe ownership metadata: %s\n' "$package_name" >&2
    exit 1
  }
  bsdtar -tf "$artifact" > "/output/$package_name.MANIFEST"
  mkdir "/inspect/$package_name"
  bsdtar -xf "$artifact" -C "/inspect/$package_name"
done

for package_name in omacalc omacut ttfx; do
  binary="/inspect/$package_name/usr/bin/$package_name"
  [[ -x "$binary" ]] || { printf 'Missing native payload: %s\n' "$binary" >&2; exit 1; }
  description=$(file -b "$binary")
  printf '%s|usr/bin/%s|%s\n' "$package_name" "$package_name" "$description" >> /output/payload-architectures.tsv
  printf '%s\n' "$description" | grep -Fq 'ELF 64-bit LSB' || { printf 'Not an ELF64 payload: %s\n' "$package_name" >&2; exit 1; }
  readelf -h "$binary" | grep -Fq 'Machine:                           AArch64' || { printf 'Not an AArch64 payload: %s\n' "$package_name" >&2; exit 1; }
done

FONT_COUNT=$(find /inspect/ttf-ia-writer/usr/share/fonts/ttf-ia-writer -type f -name '*.ttf' | wc -l)
[[ "$FONT_COUNT" -eq 16 ]] || { printf 'Expected 16 iA Writer fonts; found %s\n' "$FONT_COUNT" >&2; exit 1; }
for theme in Yaru Yaru-dark Yaru-blue Yaru-purple Yaru-sage Yaru-sage-dark Yaru-olive Yaru-red Yaru-yellow Yaru-magenta Yaru-wartybrown; do
  [[ -d "/inspect/yaru-icon-theme/usr/share/icons/$theme" ]] || { printf 'Required Yaru theme is absent: %s\n' "$theme" >&2; exit 1; }
done
[[ ! -e /inspect/yaru-icon-theme/usr/share/themes ]] || { printf 'Icon split unexpectedly contains GTK themes\n' >&2; exit 1; }
[[ ! -e /inspect/yaru-icon-theme/usr/share/icons/Yaru-gray ]]
[[ ! -e /inspect/yaru-icon-theme/usr/share/icons/Yaru-grey ]]
printf '%s\n' \
  'WARN|Yaru-gray|requested by Omarchy Vantablack but absent upstream; no silent alias was added' \
  'WARN|Yaru-grey|requested by Omarchy White but absent upstream; no silent alias was added' \
  > /output/theme-compatibility.txt

sha256sum /output/*.pkg.tar.* > /output/SHA256SUMS
printf '%s\n' \
  '[PASS] five package builds completed under native aarch64 emulation' \
  '[PASS] package check() suites completed without network source access' \
  '[PASS] package archive ownership is root:root' \
  '[PASS] omacalc, omacut and ttfx payloads are ELF64 AArch64' \
  '[PASS] ttf-ia-writer contains exactly 16 selected TrueType fonts' \
  '[WARN] Yaru-gray and Yaru-grey remain upstream Omarchy/Yaru compatibility gaps' \
  > /output/BUILD-RESULTS.txt
