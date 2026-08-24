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
| The signed ALARM RPi rootfs is not a CM5/uConsole image | The pinned August archive includes CM5 DTBs but defaults to generic `linux-aarch64` through U-Boot, `/dev/mmcblk0p1` in fstab and public default credentials | Signed extraction, kernel replacement and synthetic base configuration pass in isolated clones; apply operator credentials only to the development root before building media |
| Community kernel supply-chain gaps | Published CM5 binary has no detached signature and its PKGBUILD uses MD5; README version is stale | Rebuild source in a clean environment with SHA-256 pins and sign local packages |
| Selected DKMS layer is install/build-proven but not hardware-proven | All modules/overlays compile and install for current `linux-rpi-16k` in the real signed offline root, but load/probe/display/audio/battery and update rollback remain untested on the uConsole | Keep runtime UNKNOWN and retain the custom kernel only as a differential oracle/recovery fallback |
| DKMS source emits compiler/DT warnings | Unused locals, two integer format mismatches and four unit-address warnings reduce confidence even though both builds pass | Record exact warnings, fix/reconcile upstream, and do not suppress them in packaging |
| DKMS project glue lacks detected top-level license | Driver files carry Linux licenses, but installer/overlay redistribution terms are unclear | Study only; obtain clarification before importing or redistributing adapted glue |
| Local board package is unsigned | Its reproducible SHA-256 is locked, but no project release-signing policy or offline key exists yet | Use only for local evaluation; select a signing policy before a real image or repository is published |
| Real access/network inputs await user selection | The retained source is intentionally unchanged; admin identity, SSH key, regulatory domain, console recovery hash and optional Wi-Fi keyfile cannot be inferred safely | The file-only configuration transaction passes with synthetic inputs; collect the operator's private inputs, plan, apply, and inspect before image construction |
| First-boot initramfs is intentionally broad | Builder-host autodetection saw the container volume rather than future CM5/ext4 hardware | Build with exact kernel/output and `-S autodetect`; allow target-local autodetection only after booting on the uConsole |
| Initramfs has non-fatal ARM warnings | x86 microcode is skipped, DRM privacy-screen provider is absent, optional Renesas xHCI firmware is missing and vconsole is not yet configured | Record exact warnings; add vconsole policy in minimal config; validate that CM5-required modules/firmware exist on hardware |
| Full-root image is synthetic-only | MBR/FAT/ext4 construction and read-only inspection pass from the real configured-root lineage, but the image contains synthetic integration credentials and has not booted | Never publish/write the synthetic image; apply operator inputs to a fresh clone, rebuild with a new identity, then use read-only media preflight and a fresh SD only |
| Contradictory `dwc2` guidance in the custom kernel | Its committed config enables CM5 host mode while its overlay comment says not to load it; official `linux-rpi-16k` also enables host mode | Preserve the official setting initially and let keyboard/trackball enumeration decide; record both outcomes |
| 16 KiB kernel page size | Some proprietary applications, Electron native modules and AppImages assume 4 KiB | Report page size; test every non-repository binary; prefer source packages |
| Internal 720×1280 panel rotation | DT reports a portrait panel with 90° orientation; console and Wayland may interpret rotation differently | Validate early console, DRM mode and Hyprland transform separately |
| Aquamarine/Hyprland on Pi 5 is not an upstream board guarantee | Generic DRM/GLES support does not prove atomic KMS, modifiers or stable scanout on this panel | On-device Phase 2 gate; use Aquamarine workaround variables only diagnostically |
| Phase 2 package lock is direct-only | The 21 requested packages are exact, but rolling transitive dependencies and payload files are not content-pinned | Preflight and postflight exact direct versions; build a signed package cache before calling the image reproducible offline |
| Current Hyprland config uses Lua APIs from 0.56 | Arch ARM has the matching release, but the config has only passed syntax and fixture tests, not an on-device config load | Keep the version lock; capture `start-hyprland` stderr and `hyprctl systeminfo` before adding Omarchy |
| Omarchy source is staged but intentionally inactive | Default Quattro autostart reaches provisioning, power-profile, monitor-watch, hook and update commands that have not passed the ARM ownership audit | Stage selected trees outside `PATH`; reject activation, home seeding, services and migrations in the current installer |
| First-party Quickshell plugins default to enabled | An empty plugin list still loads non-bar infrastructure, expanding the command and package surface unexpectedly | First ARM shell config must carry an explicit `disabledPlugins` denylist and expose only allowlisted commands |
| `xdg-terminal-exec` emulated fakeroot warning | One of two builds printed an intermittent fakeroot payload warning, although the second was clean and both package bytes/ownership match | Keep the reproducible hash, but rebuild once on native ARM before signing or installing it |
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
- A locked direct Hyprland package has disappeared or advanced on the rolling
  mirror before its payload has been archived.
- Staged Omarchy source is added to `PATH`, selected as `OMARCHY_PATH`, or
  copied into a user home before its activation audit closes.
