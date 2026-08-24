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
  grep -Fxq 'omarchy-arm64-userland 4.0.0.alpha-2'
[[ -x /target/usr/bin/omarchy-launch-shell ]]
[[ -x /target/usr/bin/omarchy-shell ]]
[[ -x /target/usr/bin/omarchy-menu ]]
[[ $(find /target/usr/share/omarchy-arm64/bin -maxdepth 1 -type f | wc -l) -eq 37 ]]
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
  '[PASS] package database recorded exactly omarchy-arm64-userland 4.0.0.alpha-2' \
  '[PASS] installed payload retained the three-public/37-internal command boundary' \
  '[PASS] Pacman removal left no Omarchy userland payload behind'
