#!/usr/bin/env bash

set -euo pipefail
PACKAGE=${1:?package path is required}

install -d /target/etc /target/var/lib/pacman /target/var/cache/pacman/pkg /target/var/log
printf '%s\n' \
  '[options]' \
  'Architecture = aarch64' \
  'SigLevel = Never' \
  'LocalFileSigLevel = Never' \
  > /tmp/pacman-offline.conf

pacman --root /target \
  --dbpath /var/lib/pacman \
  --cachedir /var/cache/pacman/pkg \
  --logfile /var/log/pacman.log \
  --config /tmp/pacman-offline.conf \
  --noconfirm --nodeps --nodeps -U "$PACKAGE"

pacman --root /target --dbpath /var/lib/pacman --config /tmp/pacman-offline.conf -Q omarchy-arm64-userland |
  grep -Fxq 'omarchy-arm64-userland 4.0.0.alpha-3'
[[ -x /target/usr/bin/omarchy-launch-shell ]]
[[ -x /target/usr/bin/omarchy-shell ]]
[[ -x /target/usr/bin/omarchy-menu ]]
[[ $(find /target/usr/share/omarchy-arm64/bin -maxdepth 1 -type f | wc -l) -eq 37 ]]
[[ $(sha256sum /target/usr/share/omarchy-arm64/config/foot/foot.ini | awk '{print $1}') == a5165f8a0a93c6d7262aaae6c00c11617ffb2f35bafca73f458b6549a9dca5cf ]]
[[ $(sha256sum /target/usr/share/omarchy-arm64/themes/tokyo-night/foot.ini | awk '{print $1}') == d20c424a3e0635011e683d8a379b1e3711abaf61f7d44cf9dd25409a04558667 ]]
[[ $(sha256sum /target/usr/share/omarchy-arm64/themes/tokyo-night/shell.toml | awk '{print $1}') == 1343b48a969352eddb145e5acff00a8505d30f4f4007c4234d593b9d4b4a053b ]]
[[ -f /target/usr/share/fonts/omarchy/omarchy.ttf ]]
[[ -L /target/etc/fonts/conf.d/50-omarchy.conf ]]
[[ $(readlink /target/etc/fonts/conf.d/50-omarchy.conf) == /usr/share/fontconfig/conf.avail/50-omarchy.conf ]]
[[ ! -e /target/boot && ! -e /target/etc/systemd && ! -e /target/usr/share/omarchy-arm64/default/hypr ]]

pacman --root /target \
  --dbpath /var/lib/pacman \
  --cachedir /var/cache/pacman/pkg \
  --logfile /var/log/pacman.log \
  --config /tmp/pacman-offline.conf \
  --noconfirm -R omarchy-arm64-userland

[[ ! -e /target/usr/share/omarchy-arm64 ]]
[[ ! -e /target/usr/bin/omarchy-launch-shell && ! -e /target/usr/bin/omarchy-shell && ! -e /target/usr/bin/omarchy-menu ]]
printf '%s\n' \
  '[PASS] Pacman installed the package into a new disposable aarch64 root' \
  '[PASS] package database recorded exactly omarchy-arm64-userland 4.0.0.alpha-3' \
  '[PASS] installed payload retained the command boundary and rendered visual defaults' \
  '[PASS] Pacman removal left no Omarchy userland payload behind'
