#!/usr/bin/env bash

# Runs in the pinned aarch64 base-devel image. Provider choices are explicit,
# and all downloads must reproduce the committed content lock exactly.

set -u
set -o pipefail

EXPECTED_LOCK=/repo/research/omarchy-core-build-transaction.lock
PACMAN_CONFIG=/repo/research/container/pacman-core-extra.conf
GENERATED_LOCK=/work/transaction.lock
PACKAGES=(
  rust
  git
  meson
  qt6-base
  qt6-declarative
  qt6-multimedia
  qt6-multimedia-ffmpeg
  jack2
  sassc
)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output directory must remain empty until publication'
mkdir -p /work/db/sync /work/cache || fail 'unable to create resolver workspace'
cp -a /var/lib/pacman/local /work/db/local || fail 'unable to copy builder package database'
cp /snapshot/core.db /work/db/sync/core.db || fail 'unable to stage frozen core database'
cp /snapshot/extra.db /work/db/sync/extra.db || fail 'unable to stage frozen extra database'
# Pacman 7's DownloadUser/Landlock sandbox is unavailable in this ephemeral
# container, which receives only read-only repository and database inputs.
sed '/^DownloadUser[[:space:]]*=/d' "$PACMAN_CONFIG" > /work/pacman.conf || fail 'unable to render Pacman configuration'

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sp --needed \
  --print-format '%n|%v|%a|%r|%s|%l' "${PACKAGES[@]}" > /work/rows || fail 'frozen dependency resolution failed'
ROW_COUNT=$(awk 'END { print NR }' /work/rows)
ROW_BYTES=$(awk -F '|' '{ total += $5 } END { print total+0 }' /work/rows)
[[ "$ROW_COUNT" -eq 171 && "$ROW_BYTES" -eq 230491916 ]] || fail "resolved transaction differs: packages=$ROW_COUNT bytes=$ROW_BYTES"

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sw --needed --noconfirm "${PACKAGES[@]}" || fail 'package download/signature verification failed'

printf '# name|version|architecture|repository|kind|sha256|signature_sha256|filename|size\n' > "$GENERATED_LOCK" || fail 'unable to create generated lock'
while IFS='|' read -r name version architecture repository size url; do
  filename=${url##*/}
  package="/work/cache/$filename"
  signature="${package}.sig"
  [[ -f "$package" && -f "$signature" ]] || fail "missing payload or signature: $filename"
  observed_size=$(stat -c '%s' "$package") || fail "unable to size package: $filename"
  [[ "$observed_size" == "$size" ]] || fail "downloaded package size differs: $filename"
  kind=dependency
  case "$name" in
    git|meson|qt6-base|qt6-declarative|qt6-multimedia|sassc) kind=direct ;;
    rust) kind=provider-cargo ;;
    qt6-multimedia-ffmpeg) kind=provider-multimedia ;;
    jack2) kind=provider-jack ;;
  esac
  package_sha=$(sha256sum "$package" | awk '{print $1}') || fail "unable to hash package: $filename"
  signature_sha=$(sha256sum "$signature" | awk '{print $1}') || fail "unable to hash signature: $filename"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$name" "$version" "$architecture" "$repository" "$kind" \
    "$package_sha" "$signature_sha" "$filename" "$size" >> "$GENERATED_LOCK" || fail 'unable to append generated lock'
done < /work/rows

cmp -s "$GENERATED_LOCK" "$EXPECTED_LOCK" || fail 'downloaded dependency transaction differs from committed lock'
while IFS='|' read -r _ _ _ _ _ _ _ filename _; do
  [[ -n "$filename" && "$filename" != filename ]] || continue
  cp -p "/work/cache/$filename" "/work/cache/$filename.sig" /output/ || fail "unable to publish $filename"
done < "$GENERATED_LOCK"
cp "$GENERATED_LOCK" /output/transaction.lock || fail 'unable to publish transaction lock'

PAYLOAD_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.xz' | wc -l)
SIGNATURE_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.xz.sig' | wc -l)
[[ "$PAYLOAD_COUNT" -eq 171 && "$SIGNATURE_COUNT" -eq 171 ]] || fail 'published cache count differs'
printf '[PASS] frozen resolution      packages=%s bytes=%s\n' "$ROW_COUNT" "$ROW_BYTES"
printf '[PASS] provider selection     cargo=rust multimedia=ffmpeg jack=jack2\n'
printf '[PASS] package signatures    all official downloads verified by Pacman\n'
printf '[PASS] transaction lock      sha256=%s\n' "$(sha256sum "$GENERATED_LOCK" | awk '{print $1}')"
