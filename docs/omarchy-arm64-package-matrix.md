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
- The 27 misses resolve to 2 documented name replacements, 6 completed local
  builds, 9 pending source builds, 5 explicit deferrals and 5 omissions.
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
| visual fonts (`ttf-jetbrains-mono-nerd`, `noto-fonts`, `noto-fonts-emoji`, `ttf-liberation`) | terminal, bar and icon/text fallback | Current ALARM `any` packages resolve in the exact shell transaction | ALARM; replaces the narrower unavailable `ttf-jetbrains-mono-nerd-basic` name | Yes for first-run visuals |
| `omarchy` | commands and userland | Upstream package remains unsuitable because its `any` payload hard-depends on Limine/Snapper; the thin `omarchy-arm64-userland` pkgrel 3 builds reproducibly as `any`, passes disposable ARM64 Pacman install/remove and installs with the exact shell closure | use the thin pinned package; never install upstream package wholesale | Yes, Phase 5 only; live test pending |
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
| `omacalc` | Omarchy calculator utility | 0.2.2-2 builds/tests as ELF64 AArch64 in the pinned offline builder | live Qt/16 KiB test, then sign | Likely core UX |
| `omacut` | Omarchy capture utility | 0.4.0-2 builds as ELF64 AArch64; all 27 tests pass, including ffmpeg export and portal/QML paths | live portal/clipboard/16 KiB test, then sign | Likely core UX |
| `omarchy-nvim` | editor configuration | Omarchy PKGBUILD is `any` | build after `neovim` mapping | Optional |
| `omawrite` | writing application | Omarchy PKGBUILD declares aarch64 | build/test | Optional |
| `pinta` | image editor | missing in audited repos | source-build or omit | Optional |
| `qemu-user-static-binfmt` | emulation/build support | missing exact target package | keep on build host, not target, unless runtime use is proven | No for desktop |
| `tensaku` | Omarchy utility | Omarchy PKGBUILD is x86_64-only | inspect source; build if portable, otherwise omit | Optional |
| `tobi-try` | Omarchy utility | Omarchy PKGBUILD is `any` | build/test | To classify |
| `ttf-ia-writer` | typography | 20181225-2 builds byte-identically with the expected 16 fonts | live font-discovery test, then sign | Visual core |
| `ttf-jetbrains-mono-nerd-basic` | terminal/icon font | no exact ALARM package is needed for the selected surface; ALARM `ttf-jetbrains-mono-nerd` 3.5.1-2 is `any` and installed in the exact shell closure | use the broader official ALARM font package; functional delta is additional glyph coverage | Visual core |
| `ttfx` | terminal text effects | 0.3.2-3 builds as ELF64 AArch64; unit, golden, CLI, signal and terminal-close tests pass | live 16 KiB/session test, then sign | Supporting |
| `tzupdate` | automatic timezone | Omarchy PKGBUILD is x86_64-only | audit source build; otherwise manual/systemd alternative | Optional |
| `ufw-docker` | firewall/container integration | Omarchy PKGBUILD is `any` | build only if Docker group is selected | Optional |
| `xdg-terminal-exec` | default terminal dispatch | Omarchy PKGBUILD is `any`; 0.14.3-1 passes 23 tests with one unavailable-locale skip and builds byte-identically twice in the pinned ARM64 container | locally package, native-ARM recheck, then sign | Core integration |
| `yaru-icon-theme` | icon theme | 26.04.5.1ubuntu-3 builds and all 21 Yaru tests pass; requested `Yaru-gray`/`Yaru-grey` variants do not exist upstream | select an explicit theme fallback, live-test and sign | Visual core |
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

1. Maintain the selected first-run shell's closed 54-command runtime policy:
   51 required commands and three inactive external-display optionals. Any new
   enabled plugin or external command must fail the audit until classified.
2. Extend the exact 24-package first-run shell closure only when a reviewed
   consumer is enabled. Do not equate the upstream Arch Linux x86 package set
   with ALARM.
3. For every remaining source build, inspect upstream release assets and PKGBUILD `arch`, then
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
