# Architecture

## Target stack

```text
ClockworkPi uConsole hardware
        ↓
Raspberry Pi CM5 firmware / bootloader
        ↓
Arch Linux ARM aarch64 root filesystem
        ↓
uConsole-specific Arch kernel package + device tree
        ↓
VC4 DRM/KMS + V3D/V3DV Mesa drivers
        ↓
Hyprland + Aquamarine + UWSM
        ↓
Omarchy Quattro userland and configuration
        ↓
small, explicit ARM compatibility layer
```

The integration succeeds only if each lower layer passes before the next layer
is introduced. A visually working desktop rendered by llvmpipe is a failure,
not a partial success.

## Ownership boundaries

| Concern | Authority | May Omarchy update it? |
|---|---|---|
| Pi EEPROM/firmware boot flow, FAT boot partition | Raspberry Pi/Arch hardware layer | No |
| uConsole kernel, initramfs, DTB and overlays | Locally pinned Arch hardware package | No |
| Wi-Fi/Bluetooth firmware and Mesa/DRM userspace | Arch Linux ARM repositories | Through normal ALARM upgrades after hardware validation, never through x86 Omarchy mirrors |
| Hyprland, Aquamarine and portals | Version-locked Arch Linux ARM packages; local ARM repo only when needed | Yes, within a tested version window |
| Quickshell and Omarchy desktop services | Omarchy userland layer plus explicit ARM substitutions | Yes, only after G4 |
| Omarchy shell/Lua/QML, themes, keybindings and CLI | Omarchy upstream plus minimal overrides | Yes |
| Missing optional applications | ARM compatibility manifest | Only when the manifest declares the replacement or omission |

Hardware fixes belong in the kernel package, device tree, firmware or Arch
configuration. They must not become conditional branches scattered through
Omarchy.

## Boot and package design

The CM5 must continue to use the Raspberry Pi firmware boot chain. Limine,
BIOS/syslinux and generic UEFI ISO assumptions are outside the target design.

This conflicts with the current Quattro `omarchy` package, which declares hard
dependencies on Limine, its mkinitcpio hook, Limine/Snapper synchronization and
Snapper. It also conflicts with Omarchy routines that replace `/etc/pacman.conf`
or run a whole-system `pacman -Syyuu` against Omarchy mirrors.

The smallest acceptable compatibility mechanism is therefore expected to be:

1. Keep the Arch Linux ARM mirrorlist and package databases authoritative.
2. Package the selected Omarchy userland from its pinned source as an ARM-safe
   derivative that removes bootloader dependencies, without forking its
   userland tree.
3. Package only missing Omarchy-owned dependencies in a small, signed local ARM
   repository.
4. Carry substitutions and omissions in one declarative manifest under
   `config/arm64-overrides/`.
5. Disable or adapt only the Omarchy update hooks that replace repository or
   boot configuration. Continue using upstream migrations after each migration
   has passed an ARM/system-ownership audit.
6. Protect the kernel, firmware, DT overlay and boot configuration as a
   separately versioned hardware bundle. Record their hashes before and after
   every Omarchy update test.

This is a proposed design to validate, not a license to patch the installed
system during the research phase.

## Selected kernel baseline

The initial research selected the source and patch set from
`OuinOuin74/linux-clockwork-arch` v7.0.9 as the first custom-kernel candidate.
Subsequent prior-art research found `yota9/uconsole-cm5`, which packages the
board delta as DKMS modules and DT overlays over a stock Pi kernel. The full
source comparison is in [`hardware-source-audit.md`](hardware-source-audit.md).

The selected Phase 1 default is Arch Linux ARM `linux-rpi-16k` plus the pinned
uConsole DKMS modules and two overlays. Both current Arch kernel variants build
the complete board delta reproducibly; 16K was selected because it is the
CM5-native `bcm2712_defconfig` line and matches the strongest custom-kernel
reference. It must still pass the real-hardware and update/rollback suite.

As of 2026-08-24, the selected packages also install successfully into the
verified signed Arch Linux ARM root in an isolated native-aarch64 environment.
DKMS, the broad first-boot initramfs, both overlays and managed boot include
pass offline verification. This closes a build/integration gate only; G1–G3
remain open until the physical CM5 supplies boot, probe and V3D/V3DV evidence.

The custom kernel is retained as a differential oracle and recovery fallback,
not as the default package. Its proven boot settings, PMIC behavior and
alternate audio path are captured as test hypotheses in
[`custom-kernel-lessons.md`](custom-kernel-lessons.md). We will move a behavior
into the selected layer only when live evidence shows it is required.

If the selected baseline fails and the custom kernel is used diagnostically,
do not blindly install its release binary:

- rebuild it in a clean aarch64 build environment;
- replace weak MD5 source verification with pinned SHA-256 checks;
- review every patch against Raspberry Pi and current ClockworkPi lineages;
- remove or gate post-install edits to `config.txt`, `cmdline.txt` and `fstab`;
- resolve its conflicting `dwc2` guidance before boot;
- make known-good boot files recoverable independently of the package database.

For the selected stock-kernel/DKMS baseline:

- port the packaging, not its apt-specific installer, into a disposable Arch
  Linux ARM build;
- verify current `linux-rpi` headers expose every required symbol;
- clarify source licensing before copying project glue;
- require DKMS to build successfully before a kernel package transaction may
  become boot-default;
- retain a known-good kernel/modules/DT boot set for rollback.

The custom fallback and selected baseline use the same hardware validation and
kernel-update test. Neither may modify Omarchy.

The observed v7.0.9 configuration uses a **16 KiB page size**. That is normal
for current Pi kernels but can break proprietary binaries and some AppImages;
`getconf PAGESIZE` becomes a required compatibility datum.

## Layer gates

| Gate | Required result |
|---|---|
| G0 — Recovery | Original SD is offline and unchanged; serial/headless recovery path is documented; development media is uniquely identified |
| G1 — Boot | CM5 boots the pinned kernel and exact DT; console, SSH and networking are stable across three cold boots |
| G2 — Hardware | Internal display, input, audio, radios and battery report correctly; unsupported suspend is documented rather than guessed |
| G3 — Graphics | VC4/V3D modules and DRM nodes exist; OpenGL/Vulkan report V3D/V3DV; no llvmpipe, softpipe or lavapipe |
| G4 — Hyprland | Minimal ALARM Hyprland starts at native resolution/orientation with working input and portal |
| G5 — Core Omarchy | Quickshell, terminal, launcher, notifications, theme and keybindings pass without adding optional applications |
| G6 — Updates | A test update preserves a byte-for-byte hardware/boot manifest and completes audited migrations |

No gate is bypassed by `|| true`, suppressed stderr, or an undocumented package
replacement.

The Phase 2 installer encodes G3 as an operational prerequisite, even though it
cannot prove live GPU behavior while editing an offline root. It requires the
exact selected hardware state, locks and verifies every direct package version,
and stages only a plain user session. Apply is prohibited by procedure until a
saved on-device hardware report has no required failures and identifies V3D or
V3DV rather than a software renderer.
