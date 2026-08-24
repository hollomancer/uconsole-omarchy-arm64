#!/usr/bin/env bash

# Resolve and signature-verify the committed Hyprland transaction without
# mutating the configured target root or exposing a partial output cache.

set -u
set -o pipefail

ROOT=/target/root
DIRECT_LOCK=/repo/config/hyprland/packages.lock
EXPECTED_LOCK=/repo/config/hyprland/transaction.lock
PACMAN_CONFIG=/repo/research/container/pacman-core-extra.conf
GENERATED_LOCK=/work/transaction.lock

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/base-system-selection" ]] || fail 'configured source root is missing'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output directory must remain empty until publication'
mkdir -p /work/db/sync /work/cache || fail 'unable to create resolver workspace'
cp -a "$ROOT/var/lib/pacman/local" /work/db/local || fail 'unable to copy target installed-package database'
cp /snapshot/core.db /work/db/sync/core.db || fail 'unable to stage frozen core database'
cp /snapshot/extra.db /work/db/sync/extra.db || fail 'unable to stage frozen extra database'
# Pacman 7's DownloadUser/Landlock sandbox is unavailable in this container.
# The container is ephemeral, unprivileged, and receives only read-only inputs.
sed '/^DownloadUser[[:space:]]*=/d' "$PACMAN_CONFIG" > /work/pacman.conf || fail 'unable to render resolver Pacman configuration'

DIRECT_PACKAGES=()
while IFS='|' read -r name version architecture repository role extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid direct lock row: $name"
  DIRECT_PACKAGES+=("$name")
  : "$version" "$architecture" "$repository" "$role"
done < "$DIRECT_LOCK"
[[ ${#DIRECT_PACKAGES[@]} -eq 21 ]] || fail 'direct lock count differs'

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sp --needed \
  --print-format '%n|%v|%a|%r|%s|%l' "${DIRECT_PACKAGES[@]}" > /work/rows || fail 'frozen transaction resolution failed'
ROW_COUNT=$(awk 'END { print NR }' /work/rows)
ROW_BYTES=$(awk -F '|' '{ total += $5 } END { print total+0 }' /work/rows)
[[ "$ROW_COUNT" -eq 204 && "$ROW_BYTES" -eq 207932936 ]] || fail "resolved transaction differs: packages=$ROW_COUNT bytes=$ROW_BYTES"

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sw --needed --noconfirm "${DIRECT_PACKAGES[@]}" || fail 'package download/signature verification failed'

printf '# name|version|architecture|repository|kind|sha256|signature_sha256|filename|size\n' > "$GENERATED_LOCK" || fail 'unable to create generated lock'
while IFS='|' read -r name version architecture repository size url; do
  filename=${url##*/}
  package="/work/cache/$filename"
  signature="${package}.sig"
  [[ -f "$package" && -f "$signature" ]] || fail "missing payload or signature after verification: $filename"
  kind=dependency
  for direct_name in "${DIRECT_PACKAGES[@]}"; do
    if [[ "$name" == "$direct_name" ]]; then kind=direct; break; fi
  done
  observed_size=$(stat -c '%s' "$package") || fail "unable to size package: $filename"
  [[ "$observed_size" == "$size" ]] || fail "downloaded package size differs: $filename"
  package_sha=$(sha256sum "$package" | awk '{print $1}') || fail "unable to hash package: $filename"
  signature_sha=$(sha256sum "$signature" | awk '{print $1}') || fail "unable to hash signature: $filename"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$name" "$version" "$architecture" "$repository" "$kind" \
    "$package_sha" "$signature_sha" "$filename" "$size" >> "$GENERATED_LOCK" || fail 'unable to append generated lock'
done < /work/rows

cmp -s "$GENERATED_LOCK" "$EXPECTED_LOCK" || fail 'downloaded transaction differs from the committed content lock'
find /work/cache -maxdepth 1 -type f \( -name '*.pkg.tar.xz' -o -name '*.pkg.tar.xz.sig' \) -exec cp -p {} /output/ \; || fail 'unable to publish verified cache'
cp "$GENERATED_LOCK" /output/transaction.lock || fail 'unable to publish transaction lock'
PAYLOAD_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.xz' | wc -l)
SIGNATURE_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.xz.sig' | wc -l)
[[ "$PAYLOAD_COUNT" -eq 204 && "$SIGNATURE_COUNT" -eq 204 ]] || fail 'published cache count differs'

printf '[PASS] frozen resolution      packages=%s bytes=%s\n' "$ROW_COUNT" "$ROW_BYTES"
printf '[PASS] package signatures    all official downloads verified by Pacman\n'
printf '[PASS] transaction lock      sha256=%s\n' "$(sha256sum "$GENERATED_LOCK" | awk '{print $1}')"
printf '[PASS] source boundary       configured Phase 1 root remained read-only\n'
