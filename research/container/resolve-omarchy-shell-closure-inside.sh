#!/usr/bin/env bash

# Native-aarch64, signature-verifying resolver for the incremental Omarchy
# shell transaction. It never mutates the exact Hyprland source root.

set -u
set -o pipefail

ROOT=/target/root
DIRECT_LOCK=/repo/config/omarchy-shell/packages.lock
EXPECTED_LOCK=/repo/config/omarchy-shell/transaction.lock
PACMAN_CONFIG=/repo/research/container/pacman-core-extra.conf
GENERATED_LOCK=/work/transaction.lock
MODE=${1:-verify}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$MODE" == 'verify' || "$MODE" == 'generate' ]] || fail 'invalid resolver mode'
[[ -f "$ROOT/var/lib/uconsole-omarchy-arm64/hyprland-selection" ]] || fail 'exact Hyprland source root is missing'
[[ ! -e "$ROOT/var/lib/uconsole-omarchy-arm64/omarchy-shell-selection" ]] || fail 'source root already contains an Omarchy shell transaction'
[[ -z "$(find /output -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output directory must remain empty until publication'
if [[ "$MODE" == 'verify' ]]; then [[ -f "$EXPECTED_LOCK" ]] || fail 'committed transaction lock is missing'; fi

mkdir -p /work/db/sync /work/cache || fail 'unable to create resolver workspace'
cp -a "$ROOT/var/lib/pacman/local" /work/db/local || fail 'unable to copy target installed-package database'
cp /snapshot/core.db /work/db/sync/core.db || fail 'unable to stage frozen core database'
cp /snapshot/extra.db /work/db/sync/extra.db || fail 'unable to stage frozen extra database'
# Pacman 7's DownloadUser/Landlock sandbox is unavailable in this ephemeral,
# unprivileged resolver. All target and repository inputs remain read-only.
sed '/^DownloadUser[[:space:]]*=/d' "$PACMAN_CONFIG" > /work/pacman.conf || fail 'unable to render resolver Pacman configuration'

DIRECT_PACKAGES=()
DIRECT_VERSIONS=()
DIRECT_ARCHES=()
while IFS='|' read -r name version architecture repository role extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" && "$repository" == 'extra' ]] || fail "invalid direct lock row: $name"
  DIRECT_PACKAGES+=("$name")
  DIRECT_VERSIONS+=("$version")
  DIRECT_ARCHES+=("$architecture")
  : "$role"
done < "$DIRECT_LOCK"
[[ ${#DIRECT_PACKAGES[@]} -eq 10 ]] || fail 'direct lock count differs'

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sp --needed \
  --print-format '%n|%v|%a|%r|%s|%l' "${DIRECT_PACKAGES[@]}" > /work/rows || fail 'frozen transaction resolution failed'
ROW_COUNT=$(awk 'END { print NR+0 }' /work/rows)
ROW_BYTES=$(awk -F '|' '{ total += $5 } END { print total+0 }' /work/rows)
((ROW_COUNT >= 10 && ROW_BYTES > 0)) || fail "resolved transaction is unexpectedly small: packages=$ROW_COUNT bytes=$ROW_BYTES"

for index in "${!DIRECT_PACKAGES[@]}"; do
  name=${DIRECT_PACKAGES[$index]}
  version=${DIRECT_VERSIONS[$index]}
  architecture=${DIRECT_ARCHES[$index]}
  awk -F '|' -v wanted_name="$name" -v wanted_version="$version" -v wanted_arch="$architecture" '
    $1 == wanted_name { count++; if ($2 == wanted_version && $3 == wanted_arch && $4 == "extra") exact=1 }
    END { exit !(count == 1 && exact) }
  ' /work/rows || fail "direct package did not resolve exactly once: $name"
done

pacman --dbpath /work/db --cachedir /work/cache --logfile /work/pacman.log \
  --config /work/pacman.conf -Sw --needed --noconfirm "${DIRECT_PACKAGES[@]}" || fail 'package download or signature verification failed'

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

if [[ "$MODE" == 'verify' ]]; then
  cmp -s "$GENERATED_LOCK" "$EXPECTED_LOCK" || fail 'downloaded transaction differs from the committed content lock'
fi

while IFS='|' read -r name version architecture repository kind digest signature_digest filename size extra; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "invalid generated transaction row: $name"
  cp -p "/work/cache/$filename" "/work/cache/$filename.sig" /output/ || fail "unable to publish verified payload: $filename"
  : "$version" "$architecture" "$repository" "$kind" "$digest" "$signature_digest" "$size"
done < "$GENERATED_LOCK"
cp "$GENERATED_LOCK" /output/transaction.lock || fail 'unable to publish transaction lock'
PAYLOAD_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)
SIGNATURE_COUNT=$(find /output -maxdepth 1 -type f -name '*.pkg.tar.*.sig' | wc -l)
[[ "$PAYLOAD_COUNT" -eq "$ROW_COUNT" && "$SIGNATURE_COUNT" -eq "$ROW_COUNT" ]] || fail 'published cache count differs'

printf '[PASS] frozen resolution      packages=%s bytes=%s direct=%s\n' "$ROW_COUNT" "$ROW_BYTES" "${#DIRECT_PACKAGES[@]}"
printf '[PASS] package signatures    all official downloads verified by Pacman\n'
printf '[PASS] transaction lock      mode=%s sha256=%s\n' "$MODE" "$(sha256sum "$GENERATED_LOCK" | awk '{print $1}')"
printf '[PASS] source boundary       exact Hyprland root remained read-only\n'
