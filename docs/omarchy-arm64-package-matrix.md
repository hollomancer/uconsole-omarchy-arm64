# Omarchy ARM64 package compatibility matrix

## Scope and method

This audit compares the 148 unique, non-comment entries in
Omarchy Quattro's `install/omarchy-base.packages` at commit `d99d4fc6` against
content-pinned Arch Linux ARM aarch64 `core`, `extra`, `alarm` and `aur` sync
databases observed on 2026-08-24. It also verifies missing-package architecture
claims against the pinned `omarchy-pkgs` tree at `40ddd6be`.

- **121/148** names have an exact aarch64 repository match.
- **27/148** do not have an exact repository name match.
- All **148/148** have an explicit category, required group and disposition;
  there are no implicit or unknown dispositions.
- The 27 misses resolve to 2 documented name replacements, 1 completed local
  build, 14 pending source builds, 5 explicit deferrals and 5 omissions.
- An exact match is inventory evidence, not proof that runtime behavior works.
- A missing exact name is not necessarily incompatible; it may be an
  Omarchy-owned package, an alternate Arch name, or an optional x86 application.

The authoritative full matrix is
[`../research/package-audit/omarchy-base-packages.tsv`](../research/package-audit/omarchy-base-packages.tsv).
The hand-reviewed policy is
[`../config/arm64-overrides/omarchy-base-package-policy.tsv`](../config/arm64-overrides/omarchy-base-package-policy.tsv),
and the audit fails if either it or any pinned input produces a different
package name, repository, version, architecture or count.

## Core stack anchors

| Package/component | Omarchy use | ARM64 status observed | Proposed source/replacement | Required |
|---|---|---|---|---|
| `hyprland` | compositor | ALARM aarch64 0.56.1-3 | ALARM | Yes, Phase 2 |
| `aquamarine` | DRM backend | ALARM aarch64 0.14.0-2 | ALARM | Yes, transitive |
| `quickshell` | bar, menu, OSD, notifications | ALARM aarch64 0.3.1-1 | ALARM | Yes, core Omarchy UX |
| `uwsm` | Wayland session management | ALARM `any` 0.26.7-1 | ALARM | Yes |
| `xdg-desktop-portal-hyprland` | portals/screenshare integration | ALARM aarch64 1.4.1-1 | ALARM | Yes |
| `mesa` / `libdrm` | V3D graphics userspace | ALARM aarch64; Mesa 1:26.2.1-1, libdrm 2.4.134-1 | ALARM | Yes, Phase 1 gate |
| `vulkan-broadcom` | V3DV Vulkan ICD | ALARM aarch64 1:26.2.1-1 | ALARM | Yes for requested validation |
| `pipewire` / `wireplumber` | audio/session graph | ALARM aarch64 | ALARM | Yes |
| `foot` | terminal | ALARM aarch64 1.27.0-1 | ALARM | Yes for core UX |
| `omarchy` | commands and userland | PKGBUILD is `any`, but public aarch64 repo is absent and package hard-depends on Limine/Snapper boot machinery | rebuild thin ARM-safe package from pinned upstream | Yes, Phase 5 only |
| `omarchy-settings` | broad `/etc` defaults | PKGBUILD is `any`; contents overlap boot, logind, networking and initramfs ownership | split/audit; install only approved settings | Partly; not wholesale |

## Exact-name misses requiring classification

“Omarchy PKGBUILD arch” describes build metadata found upstream, not a completed
build result.

| Package | Initial Omarchy role | Current ARM evidence | Candidate disposition | Core? |
|---|---|---|---|---|
| `aether` | desktop application | Omarchy PKGBUILD declares aarch64 | build/test from pinned PKGBUILD | Optional |
| `asdcontrol` | Apple Studio Display control | Omarchy PKGBUILD is x86_64-only and hardware is irrelevant | explicitly omit | No |
| `cliamp` | terminal media utility | Omarchy PKGBUILD declares aarch64 | build/test | Optional |
| `dotnet-runtime` | application runtime | no exact current ALARM name in audit | resolve actual consumer/version; upstream ARM binary or omit consumer | Unknown |
| `herdr` | Omarchy utility | Omarchy PKGBUILD declares aarch64 | build/test | To classify |
| `hyprland-preview-share-picker` | screen-share picker | Omarchy PKGBUILD is x86_64-only | source-build audit or use portal-compatible picker | Optional functionality |
| `localsend` | file sharing app | Omarchy PKGBUILD declares aarch64 | build/test; inspect bundled binaries | Optional |
| `mise-bin` | development runtime manager | Omarchy PKGBUILD declares aarch64 | build/test or official upstream ARM64 binary | Optional/development |
| `nvim` | editor command | no package by that exact name | use ALARM `neovim` after confirming it provides `nvim` | Optional/core shell tooling |
| `obs-studio` | recording/streaming | missing in audited repos | source-build or omit; benchmark V3D encoding path | Optional |
| `obsidian` | notes app | no exact package in the frozen ALARM databases | official ARM64 if compatible with 16 KiB pages, otherwise omit | Optional |
| `omacalc` | Omarchy calculator utility | Omarchy PKGBUILD declares aarch64 | build/test | Likely core UX |
| `omacut` | Omarchy capture utility | Omarchy PKGBUILD declares aarch64 | build/test with portal and clipboard | Likely core UX |
| `omarchy-nvim` | editor configuration | Omarchy PKGBUILD is `any` | build after `neovim` mapping | Optional |
| `omawrite` | writing application | Omarchy PKGBUILD declares aarch64 | build/test | Optional |
| `pinta` | image editor | missing in audited repos | source-build or omit | Optional |
| `qemu-user-static-binfmt` | emulation/build support | missing exact target package | keep on build host, not target, unless runtime use is proven | No for desktop |
| `tensaku` | Omarchy utility | Omarchy PKGBUILD is x86_64-only | inspect source; build if portable, otherwise omit | Optional |
| `tobi-try` | Omarchy utility | Omarchy PKGBUILD is `any` | build/test | To classify |
| `ttf-ia-writer` | typography | Omarchy PKGBUILD is `any` | build/package font | Visual core |
| `ttf-jetbrains-mono-nerd-basic` | terminal/icon font | Omarchy PKGBUILD is `any` | build/package font | Visual core |
| `ttfx` | font utility | Omarchy PKGBUILD declares aarch64 | build/test | Supporting |
| `tzupdate` | automatic timezone | Omarchy PKGBUILD is x86_64-only | audit source build; otherwise manual/systemd alternative | Optional |
| `ufw-docker` | firewall/container integration | Omarchy PKGBUILD is `any` | build only if Docker group is selected | Optional |
| `xdg-terminal-exec` | default terminal dispatch | Omarchy PKGBUILD is `any`; 0.14.3-1 passes 23 tests with one unavailable-locale skip and builds byte-identically twice in the pinned ARM64 container | locally package, native-ARM recheck, then sign | Core integration |
| `yaru-icon-theme` | icon theme | Omarchy PKGBUILD is `any` | build/package | Visual core |
| `yay` | AUR helper/update path | Omarchy PKGBUILD declares aarch64 | build in clean environment; never use as root | Update tooling, conditional |

## Reproduction and remaining investigation

Regenerate and compare the matrix with:

```sh
research/audit-omarchy-base-packages.sh --check \
  --source-archive /path/to/omarchy-d99d4fc6.tar.gz \
  --package-source-archive /path/to/omarchy-pkgs-40ddd6be.tar.gz \
  --core-db /path/to/core.db \
  --extra-db /path/to/extra.db \
  --alarm-db /path/to/alarm.db \
  --aur-db /path/to/aur.db
```

The exact hashes are in
[`../research/package-audit/inputs.yaml`](../research/package-audit/inputs.yaml).
The remaining work is behavioral rather than name matching:

1. Extract every systemd unit, shell command invocation and Lua/QML external
   executable reference from the pinned Omarchy tree and reduce the proposed
   68-package core group to a proven command-consumer closure.
2. Resolve the selected core dependency closure against pinned ALARM databases.
   Do not equate the upstream Arch Linux x86 package set with ALARM.
3. For every source build, inspect upstream release assets and PKGBUILD `arch`, then
   follow the mandated preference order: ALARM, official ARM64 binary, AUR,
   source build, compatible replacement, disable optional feature.
4. Inspect binaries with `file` and `readelf`; inspect Electron/AppImage payloads
   and native modules for aarch64 and 16 KiB-page compatibility.
5. Build candidates in a clean native-aarch64 or full-system-QEMU Arch Linux ARM
   environment. Record source commit, checksums, build log, license and
   reproducible package hash.
6. Test package install/uninstall and runtime behavior on the CM5. Record the
   functional difference of every replacement.
7. Extend the audit from the base list to transitive dependencies and command
   consumers. CI must continue to fail on an unclassified dependency, an
   undocumented substitution or a new x86-only artifact.

Each final row will contain: package, version constraint, consumers, category,
required group, repository evidence, declared architectures, binary
architectures, build result, runtime result, 16 KiB-page result, replacement,
functional delta, license, source pin and last verification date.
