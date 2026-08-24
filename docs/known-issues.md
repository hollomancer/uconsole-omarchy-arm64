# Known issues and expected blockers

These items are unresolved until hardware or build evidence closes them.

| Blocker | Why it matters | Current containment |
|---|---|---|
| No published Omarchy aarch64 repository | Public stable/edge aarch64 database endpoints returned 404 | Build a small pinned ARM repository; recheck upstream before doing so |
| Official Omarchy ISO is x86_64 and its ARM plan excludes SBC boot | ISO includes x86 boot assets and generic UEFI assumptions | Never use it as the CM5 foundation |
| Omarchy package hard-depends on Limine/Snapper boot integration | Can seize ownership of the Pi boot chain or make the package uninstallable | Create a thin ARM-safe packaging adaptation; do not alter Omarchy userland |
| Omarchy pacman refresh/update routines replace repository configuration | x86 Omarchy mirrors are not Arch Linux ARM repositories; update could downgrade or corrupt the system | All 28 update-boundary commands are content-locked and classified; unsafe paths remain unavailable and candidate changes fail the read-only update planner |
| Omarchy settings owns broad `/etc` policy | Includes logind, networking, initramfs and boot-adjacent configuration | Split and explicitly allow settings; never install wholesale in Phase 1 |
| No official ClockworkPi CM5 image | Vendor's current image path targets CM4 | Use vendor sources plus the current community CM5 patch set, with explicit provenance |
| The signed ALARM RPi rootfs is not a CM5/uConsole image | The pinned August archive includes CM5 DTBs but defaults to generic `linux-aarch64` through U-Boot, `/dev/mmcblk0p1` in fstab and public default credentials | Signed extraction, kernel replacement and synthetic base configuration pass in isolated clones; apply operator credentials only to the development root before building media |
| Community kernel supply-chain gaps | Published CM5 binary has no detached signature and its PKGBUILD uses MD5; README version is stale | Rebuild source in a clean environment with SHA-256 pins and sign local packages |
| Selected DKMS layer is install/build-proven but not hardware-proven | All modules/overlays compile and install for current `linux-rpi-16k` in the real signed offline root, but load/probe/display/audio/battery and update rollback remain untested on the uConsole | Keep runtime UNKNOWN and retain the custom kernel only as a differential oracle/recovery fallback |
| DKMS source emits compiler/DT warnings | Unused locals, two integer format mismatches and four unit-address warnings reduce confidence even though both builds pass | Record exact warnings, fix/reconcile upstream, and do not suppress them in packaging |
| DKMS project glue lacks detected top-level license | Driver files carry Linux licenses, but installer/overlay redistribution terms are unclear; a 2026-08-24 GitHub API recheck still found null license metadata, a 404 license endpoint and no top-level license file | Keep the built package local-evaluation-only; obtain clarification before importing or redistributing adapted glue |
| Local board package is unsigned | Its reproducible SHA-256 is locked, but no project release-signing policy or offline key exists yet | Use only for local evaluation; select a signing policy before a real image or repository is published |
| Real access/network inputs await user selection | A fresh signed/hardware/base-package root is retained, but admin identity, SSH key, regulatory domain, console recovery hash, timezone and optional Wi-Fi keyfile cannot be inferred safely | The network-disabled read-only plan, portable private-hash helper, explicit apply confirmation and configured-root inspector pass with synthetic inputs; collect real inputs, review the plan, apply, and accept post-apply inspection before building an image |
| No development SD is currently inserted | The macOS host sees the USB reader but its only external physical disk is the non-removable 1 TB `SSDmini` project drive | The read-only macOS planner rejects `SSDmini` even with matching identity fields; insert a fresh removable card, inventory it, and rerun the exact identity preflight before designing a writer |
| First-boot initramfs is intentionally broad | Builder-host autodetection saw the container volume rather than future CM5/ext4 hardware | Build with exact kernel/output and `-S autodetect`; allow target-local autodetection only after booting on the uConsole |
| Initramfs has non-fatal ARM warnings | x86 microcode is skipped, DRM privacy-screen provider is absent, optional Renesas xHCI firmware is missing and vconsole is not yet configured | Record exact warnings; add vconsole policy in minimal config; validate that CM5-required modules/firmware exist on hardware |
| Prepared full-root image is synthetic-only | The 8 GiB MBR/FAT/ext4 image passes read-only filesystem, partition, six-state, three-config and 51-command inspection, but it contains synthetic integration credentials and has not booted | Keep its SHA-256 evidence but never publish/write the artifact; apply operator inputs to a fresh clone, rebuild with a new identity, then use read-only media preflight and a fresh SD only |
| Private off-target root archives are retained | Both removed Docker roots restore exactly from mode-0600 archives on `SSDmini`, but they contain synthetic integration credentials and consume about 6.2 GB | Never publish them; retain through fresh-root reconstruction, then make an explicit archive-retention decision |
| Whole image is not byte-reproducible | Semantic trees match, but all 415 FAT entry times, nearly every ext4 ctime, the ext4 directory-hash seed, mount/write metadata and allocation counts differ | Semantic repeatability was accepted for bring-up; retain the evidence and revisit controlled offline filesystem population only if release images require exact bytes |
| Contradictory `dwc2` guidance in the custom kernel | Its committed config enables CM5 host mode while its overlay comment says not to load it; official `linux-rpi-16k` also enables host mode | Preserve the official setting initially and let keyboard/trackball enumeration decide; record both outcomes |
| 16 KiB kernel page size | Some proprietary applications, Electron native modules and AppImages assume 4 KiB | Report page size; test every non-repository binary; prefer source packages |
| Internal 720×1280 panel rotation | DT reports a portrait panel with 90° orientation; console and Wayland may interpret rotation differently | Validate early console, DRM mode and Hyprland transform separately |
| Aquamarine/Hyprland on Pi 5 is not an upstream board guarantee | Generic DRM/GLES support does not prove atomic KMS, modifiers or stable scanout on this panel | On-device Phase 2 gate; use Aquamarine workaround variables only diagnostically |
| Phase 2 cache is not a signed project repository | The exact 204-package transaction and detached signatures are content-locked and resolver-verified, but update/distribution metadata is not project-signed | Use the reviewed local cache for bring-up only; design a separately signed ARM repository after live Hyprland passes |
| Current Hyprland config uses Lua APIs from 0.56 | Arch ARM has the matching release, but the config has only passed syntax and fixture tests, not an on-device config load | Keep the version lock; capture `start-hyprland` stderr and `hyprctl systeminfo` before adding Omarchy |
| Omarchy source is staged but intentionally inactive | The audit tree is broader than the runnable surface and must never become `OMARCHY_PATH` | Runtime is a separate thin package; the inert stage remains outside `PATH` and rejects activation |
| First-party Quickshell plugins default to enabled | An empty plugin list still loads non-bar infrastructure, expanding the command and package surface unexpectedly | All 37 manifests are locked; 21 plugins are explicitly disabled and any inventory change fails the activation audit |
| Thin Omarchy userland is off-target proven but not live-proven | Two package builds, exact 24-package shell transaction, inactive home seed and disposable Pacman install/remove pass, but QML/IPC, panel geometry, portals and enabled hardware panels have not run on the CM5 | Do not launch it until hardware and minimal Hyprland pass; then test one enabled plugin group at a time |
| No reviewed session handoff exists yet | Copying upstream Hyprland/autostart defaults would introduce many unclassified commands and bypass the minimal compositor baseline | Keep the prepared image inactive; after the live Hyprland gate, add only the reviewed shell wrapper to the existing session and validate before/after |
| `xdg-terminal-exec` emulated fakeroot warning | One of two builds printed an intermittent fakeroot payload warning, although the second was clean and both package bytes/ownership match | Keep the reproducible hash, but rebuild once on native ARM before signing or installing it |
| GPU false positives | A desktop can start with llvmpipe/lavapipe | Treat any software renderer as FAIL and stop before Omarchy |
| Battery/power patch maturity | AXP20x reporting and power key behavior are board-specific and still evolving in community kernels | Charge/discharge and shutdown tests; compare active kernel lineages |
| Suspend/wake is unknown | An apparent suspend can strand the device or drain battery | Do not automate; test only with recovery and preserve journals |
| Audio route/amplifier behavior is board-specific | A listed ALSA device does not prove speaker/headphone switching | Validate physical outputs, mute and insertion state |
| Five core local packages are built but not target-proven | `omacalc`, `omacut`, `ttf-ia-writer`, `ttfx` and `yaru-icon-theme` pass the pinned offline AArch64 build; GUI, portal, font/theme discovery and 16 KiB-page behavior still need the CM5 | Keep activation blocked; install only into a disposable image, then test and sign the exact artifacts |
| Current Yaru lacks two names requested by Omarchy | `Yaru-gray` (Vantablack) and `Yaru-grey` (White) are absent from the pinned upstream release; silently aliasing them would conceal a visual difference | Choose and document an explicit fallback after live comparison, or package a reviewed theme that supplies the names |
| Emulated `makepkg` prints an intermittent fakeroot payload warning | The warning appears when entering fakeroot under the AArch64 container, although every final package MTREE proves inherited `uid=0 gid=0` and repeat artifact hashes are checked | Retain the ownership gate and repeat once on native ARM before signing |
| Historical Omarchy migrations | Replaying x86-oriented migrations on a fresh ARM port can mutate system state unexpectedly | All 87 are content-locked as `baseline-do-not-run`; the preparation transaction creates exact empty markers without executing scripts and rejects conflicting state |
| Kernel/firmware updates versus Omarchy updates | A generic system update could replace the known-good boot set | Separate hardware package ownership and compare boot manifests around updates |
| SoC discovery differs from PCs | `lspci` may not show platform GPU/display devices | Keep it in reports but use DRM sysfs, DT and bound-driver evidence |

## Failures that stop progression

- The development target cannot be uniquely distinguished from the working
  card or host disk.
- The kernel/DT source and exact boot files are not reproducible.
- SSH/serial recovery is unavailable before panel changes.
- Any required input, panel, audio, radio or battery function regresses across
  cold boots.
- OpenGL or Vulkan selects llvmpipe, softpipe or lavapipe.
- An update modifies hardware-owned boot files without an approved hardware
  package transition.
- A required package remains `unknown` in the compatibility manifest.
- The retained local Hyprland payload cache is discarded before a durable
  project archive or signed repository exists.
- Inert staged Omarchy source is added to `PATH`, selected as `OMARCHY_PATH`, or
  copied into a user home; only the reviewed thin package may become runtime.
