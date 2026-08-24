# Known issues and expected blockers

These items are unresolved until hardware or build evidence closes them.

| Blocker | Why it matters | Current containment |
|---|---|---|
| No published Omarchy aarch64 repository | Public stable/edge aarch64 database endpoints returned 404 | Build a small pinned ARM repository; recheck upstream before doing so |
| Official Omarchy ISO is x86_64 and its ARM plan excludes SBC boot | ISO includes x86 boot assets and generic UEFI assumptions | Never use it as the CM5 foundation |
| Omarchy package hard-depends on Limine/Snapper boot integration | Can seize ownership of the Pi boot chain or make the package uninstallable | Create a thin ARM-safe packaging adaptation; do not alter Omarchy userland |
| Omarchy pacman refresh/update routines replace repository configuration | x86 Omarchy mirrors are not Arch Linux ARM repositories; update could downgrade or corrupt the system | Preserve ALARM configuration and audit/update only approved userland paths |
| Omarchy settings owns broad `/etc` policy | Includes logind, networking, initramfs and boot-adjacent configuration | Split and explicitly allow settings; never install wholesale in Phase 1 |
| No official ClockworkPi CM5 image | Vendor's current image path targets CM4 | Use vendor sources plus the current community CM5 patch set, with explicit provenance |
| Community kernel supply-chain gaps | Published CM5 binary has no detached signature and its PKGBUILD uses MD5; README version is stale | Rebuild source in a clean environment with SHA-256 pins and sign local packages |
| DKMS candidate not yet compiled on ALARM | The source targets stock Pi kernels, but current `linux-rpi`/`linux-rpi-16k` header compatibility is unproven; the first isolated builder attempt hit local container storage/runtime failure | Keep result UNKNOWN, retain custom-kernel default, and repeat the pinned two-header build before image integration |
| DKMS project glue lacks detected top-level license | Driver files carry Linux licenses, but installer/overlay redistribution terms are unclear | Study only; obtain clarification before importing or redistributing adapted glue |
| `dwc2` conflict in current CM5 kernel project | Shipped config enables it while the CM5 overlay warns not to load it | Resolve by source/boot testing before creating templates |
| 16 KiB kernel page size | Some proprietary applications, Electron native modules and AppImages assume 4 KiB | Report page size; test every non-repository binary; prefer source packages |
| Internal 720×1280 panel rotation | DT reports a portrait panel with 90° orientation; console and Wayland may interpret rotation differently | Validate early console, DRM mode and Hyprland transform separately |
| Aquamarine/Hyprland on Pi 5 is not an upstream board guarantee | Generic DRM/GLES support does not prove atomic KMS, modifiers or stable scanout on this panel | On-device Phase 2 gate; use Aquamarine workaround variables only diagnostically |
| GPU false positives | A desktop can start with llvmpipe/lavapipe | Treat any software renderer as FAIL and stop before Omarchy |
| Battery/power patch maturity | AXP20x reporting and power key behavior are board-specific and still evolving in community kernels | Charge/discharge and shutdown tests; compare active kernel lineages |
| Suspend/wake is unknown | An apparent suspend can strand the device or drain battery | Do not automate; test only with recovery and preserve journals |
| Audio route/amplifier behavior is board-specific | A listed ALSA device does not prove speaker/headphone switching | Validate physical outputs, mute and insertion state |
| 27 exact package-name misses | Core UX, optional apps and build-host dependencies are mixed together | Classify by consumer and required group before building or substituting |
| Historical Omarchy migrations | Replaying x86-oriented migrations on a fresh ARM port can mutate system state unexpectedly | Audit and seed migration state deliberately; never mark a failed migration complete |
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
