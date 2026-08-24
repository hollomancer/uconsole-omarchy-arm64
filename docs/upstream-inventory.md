# Upstream project inventory

Observed on **2026-08-24**. Commit pins are an investigation baseline, not a
claim that every project is stable or compatible. The exact pins are also
machine-readable in [`../research/upstream-lock.yaml`](../research/upstream-lock.yaml).
Closely related community implementations and their limitations are assessed
separately in [`prior-art.md`](prior-art.md).

## Primary projects

| Project | Role | Active/default branches | Observed tip and recent activity | Architecture assumption | Decision |
|---|---|---|---|---|---|
| [basecamp/omarchy](https://github.com/basecamp/omarchy) | Omarchy userland, commands, Quickshell and Hyprland configuration | `quattro` (default), `master`, `dev`, `rc` | `quattro` at `d99d4fc6` on 2026-08-24; v4.0.0 published 2026-08-14 | Quattro's shell/Lua/QML payload is largely architecture-independent; its declared package closure is not | Pin and consume selected userland; do not run it as an installer |
| [omacom-io/omarchy-iso](https://github.com/omacom-io/omarchy-iso) | Official installer/ISO | `quattro` (default) | `268bac16d` on 2026-08-23 | ISO profile explicitly sets `arch="x86_64"` and contains x86 BIOS/UEFI boot assets | Do not port the ISO |
| [Omarchy ISO ARM64 plan](https://github.com/omacom-io/omarchy-iso/blob/quattro/plans/aarch64-support.md) | Official ARM64 design experiment | file on `quattro` | Current plan inspected 2026-08-24 | Targets generic UEFI+ACPI ARM64; explicitly excludes SBC boot flows such as Raspberry Pi firmware/U-Boot | Useful confirmation that CM5 belongs below Omarchy, not in its ISO |
| [omacom-io/omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs) | Omarchy package build definitions and repositories | `master`; historical `add-aarch64-support` is fully behind `master` | `40ddd6be1` on 2026-08-24 | Build tooling accepts `aarch64` and uses Arch Linux ARM/QEMU, but README says only x86_64 is published | Reuse PKGBUILDs and build metadata; expect to build a small ARM repository |
| [omacom-io/omarchy-mirror](https://github.com/omacom-io/omarchy-mirror) | Arch mirror used by Omarchy | `master` | `904b…` on 2026-07-20 | Mirrors Arch Linux x86 repositories | Do not point Arch Linux ARM at this mirror |
| [Arch Linux ARM PKGBUILDs](https://github.com/archlinuxarm/PKGBUILDs) | ARM64 distribution package sources | `master` | `a75cb…` on 2026-08-24 | Native Arch Linux ARM packaging | Base distribution authority |
| [Arch Linux ARM downloads](https://archlinuxarm.org/about/downloads) | Generic ARM root filesystems | rolling downloads | Raspberry Pi aarch64 rootfs observed updated 2026-08-05 | No dedicated Raspberry Pi 5/CM5 platform entry; closest supported rootfs requires a separately supplied kernel | Use the signed RPi aarch64 rootfs, pin its digest, and provide the uConsole kernel |
| [OuinOuin74/linux-clockwork-arch](https://github.com/OuinOuin74/linux-clockwork-arch) | Arch-packaged uConsole kernels and DT overlays | `main` | `eef4936b1`; release v7.0.9 on 2026-05-23 | Has distinct CM4 and CM5 aarch64 packages and CM5 uConsole overlay | Best current Arch-specific Phase 1 baseline, subject to source rebuild and audit |
| [clockworkpi/uConsole](https://github.com/clockworkpi/uConsole) | Vendor hardware sources, firmware, schematics and images | `master` | `53a05e…` on 2026-08-01 | Published image is CM4; no official CM5 image | Hardware authority, not a ready CM5 distribution |
| [raspberrypi/linux](https://github.com/raspberrypi/linux) | Raspberry Pi kernel base | `rpi-6.18.y` (default at observation) | `16f1da…` on 2026-08-24 | Pi 5/CM5 SoC and DRM support, without uConsole panel/power additions | Upstream base for reviewing every carried patch |
| [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland) | Wayland compositor | `main` | `d850446…` on 2026-08-24; v0.56.2 released 2026-08-05 | Portable Linux DRM/Wayland compositor; no CM5 guarantee | Use the Arch Linux ARM binary first |
| [hyprwm/aquamarine](https://github.com/hyprwm/aquamarine) | Hyprland's DRM backend | `main` | `cf056d…` on 2026-08-24; v0.14.0 current | Native DRM backend requiring GBM/GLES3-capable graphics | Validate atomic KMS, modifiers and direct rendering on device |
| [Mesa V3D/V3DV documentation](https://docs.mesa3d.org/drivers/v3d.html) | Pi OpenGL ES and Vulkan userspace drivers | current documentation | inspected 2026-08-24 | Documents V3D/V3DV for Raspberry Pi 4/5, with VC4 DRM/KMS integration | Graphics authority above the kernel |

## Current CM5/uConsole kernel lineages

These projects overlap. They should be mined for patches, not stacked or mixed
unreviewed.

| Project | Current evidence | Packaging fit | Intended use |
|---|---|---|---|
| [OuinOuin74/linux-clockwork-arch](https://github.com/OuinOuin74/linux-clockwork-arch) | Released CM5 Arch package, overlay, panel, backlight, AXP20x battery changes, audio switch and Broadcom firmware config | Native Arch PKGBUILD | Initial reproducible baseline |
| [ak-rex/rpi-linux](https://github.com/ak-rex/rpi-linux) | Active `rpi-6.12.y` and `rpi-7.1.y` uConsole branches | Kernel source, not a complete Arch delivery path | Compare patch provenance and newer fixes |
| [ClusterM/ClockworkPi-linux](https://github.com/ClusterM/ClockworkPi-linux) | Active `clockworkpi-7.2.y-live`, recent CM5 and battery work | APT-oriented packaging | Review/forward-port improvements; do not install its packages on Arch |
| [cuu/ClockworkPi-linux](https://github.com/cuu/ClockworkPi-linux) | ClockworkPi 6.12-era source lineage | Kernel source | Compare against current official CM4 work |

The official uConsole issue tracker still has an open [CM5 support
request](https://github.com/clockworkpi/uConsole/issues/29). Community reports,
including [a first-hand Arch Linux ARM CM5
report](https://forum.clockworkpi.com/t/arch-linux-arm-for-uconsole-w-rpi-cm5/16382),
show feasibility but are not a reproducible supply chain.

## ARM64 status of Omarchy

The status is **promising userland, incomplete distribution**:

1. Quattro's `omarchy` and `omarchy-settings` PKGBUILDs declare `arch=('any')`.
2. The package builder has an aarch64 path and many Omarchy-owned PKGBUILDs
   already declare `aarch64` or `any`.
3. The public stable and edge repository URLs tested for `aarch64` returned
   HTTP 404, while their x86_64 counterparts returned HTTP 200. The package
   repository's own README also states that only x86_64 is published.
4. The official ISO remains x86_64-specific. Its ARM64 plan is not implemented
   and excludes SBC boot mechanisms anyway.
5. [PR #1897](https://github.com/basecamp/omarchy/pull/1897), an Omarchy 3.x
   aarch64 attempt, was closed without merge. It is reference material, not an
   upstream-supported installation path.
6. Active community forks such as
   [omarchy-mac/omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) and
   [ggalancs/omarchy-arm-utm](https://github.com/ggalancs/omarchy-arm-utm)
   demonstrate Quattro work on ARM, but target Apple/Asahi or virtual UEFI
   machines rather than a CM5.

Omarchy Quattro currently uses **Quickshell** for its bar, menus, OSD and
notification UI. Waybar and Mako should therefore not be treated as the current
canonical experience.

## Package repository observations

The following URLs were probed directly on 2026-08-24:

| Endpoint | Observed result |
|---|---|
| `https://stable.mirror.omarchy.org/core/x86_64/core.db` | HTTP 200 |
| `https://stable.mirror.omarchy.org/core/aarch64/core.db` | HTTP 404 |
| `https://pkgs.omarchy.org/stable/x86_64/omarchy.db` | HTTP 200 |
| `https://pkgs.omarchy.org/stable/aarch64/omarchy.db` | HTTP 404 |
| `https://pkgs.omarchy.org/edge/x86_64/omarchy.db` | HTTP 200 |
| `https://pkgs.omarchy.org/edge/aarch64/omarchy.db` | HTTP 404 |

These are point-in-time observations and must be rechecked by the future audit
tool. They are not a reason to rewrite pacman configuration dynamically.
