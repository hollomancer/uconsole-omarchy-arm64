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
| Host identity, admin/SSH access, locale, NetworkManager and Bluetooth service policy | Minimal Arch base-system layer | No; Omarchy may consume networking but may not replace its owner |
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

The compatibility mechanism is now implemented as:

1. Keep the Arch Linux ARM mirrorlist and package databases authoritative.
2. Package the selected Omarchy Quickshell userland from pinned source as
   `omarchy-arm64-userland`, without copying upstream Hyprland, boot, service,
   migration or package/update ownership.
3. Package only missing Omarchy-owned dependencies in a small, signed local ARM
   repository.
4. Carry substitutions and omissions in one declarative manifest under
   `config/arm64-overrides/`.
5. Expose only three reviewed userland wrappers. Keep upstream update and
   migration commands absent; initialize the 87 pinned historical migrations
   as a no-run baseline and audit each future migration before promotion.
6. Protect the kernel, firmware, DT overlay and boot configuration as a
   separately versioned hardware bundle. Record their hashes before and after
   every Omarchy update test.

The exact Hyprland transaction, 24-package Omarchy shell closure, thin package
and user-preparation transactions pass native off-target tests. An 8 GiB image
assembled from that root passes read-only filesystem, partition, state,
configuration and 51-command inspection with activation explicitly absent.
It contains synthetic credentials and is not a development-card artifact.
This is not permission to patch or launch these layers before the live hardware
and minimal Hyprland gates pass.

Two independent image builds from the same immutable root pass an exhaustive
read-only semantic comparison: every path, type, mode, owner, regular-file size
and digest, symlink target, and normalized manifest field matches. Their FAT,
ext4 and whole-image bytes differ, so the current guarantee is procedural and
semantic repeatability—not byte-for-byte image reproducibility. Whether to
normalize filesystem metadata/layout further is an explicit project decision;
package and input locks remain byte-addressed regardless.

The variance is not a single mutable superblock field. All 415 FAT entries
have different creation/modification times; 109,513 of 109,514 ext4 entries
have different ctimes; and ext4 carries different directory-hash seeds,
mount/write times, lifetime writes and allocation counts. Exact image bytes
would therefore require offline, controlled filesystem population rather than
the current mount-and-copy builder. Semantic repeatability is the recommended
bring-up boundary.

The operator accepted that boundary on 2026-08-24. Byte-identical FAT/ext4
images are deferred; this does not relax package hashes, source locks,
per-file semantic comparison, read-only image inspection or hardware gates.

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

The next Arch-owned layer also passes native-aarch64 integration on a
disposable clone: an exact local NetworkManager/sudo/BlueZ closure, non-root
admin, key-only SSH, locked source accounts, locale/time/radio policy and one
network owner. Secret inputs are file-only and excluded from public selection
state. A fresh retained root has now independently repeated signed extraction,
the selected hardware transaction and the package-only base transaction. It
stops before configuration with both source accounts still unsafe, no SSH host
identity and no upper-layer state. This does not close G1 because the operator's
real inputs have not been applied and no CM5 has booted it.

The operator transition is now a separate network-disabled boundary. Plan
mounts the retained root and private files read-only; apply requires the target
volume name twice, proves idempotence, then reopens the result read-only. The
post-apply inspector reuses the production image-plan gate and validates
effective SSH, NetworkManager, services, locale and absence of a cloned host
key. Its configured-archive integration passes on a Linux-semantics ext4 image;
no real operator configuration has yet been applied.

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

The later package/image tools preserve the same boundary. The Omarchy shell
installer requires the exact Hyprland state and records `session_activated=no`,
`uwsm_enabled=no`, `hardware_owned=no` and `updates_owned=no`. The user
preparer seeds only reviewed home content. The image builder's
`--require-omarchy-prepared` option requires those exact states and refuses any state
that claims activation; it does not turn the shell on. A separate, reviewed
live-session handoff is intentionally still missing.

## ARM update boundary

The upstream updater is not portable as an indivisible command. It combines a
Snapper snapshot, Omarchy/x86 keyring bootstrapping, a rolling `pacman -Syu`,
all pending migrations, AUR updates, orphan removal and reboot handling. Other
reachable commands overwrite `pacman.conf`, install an x64 EFI firmware binary
under `/boot`, rebuild Limine or perform a Limine/Btrfs factory reset.

The ARM mechanism therefore promotes inputs, not the upstream updater:

1. `plan-omarchy-update.sh` verifies an explicit source commit and archive
   SHA-256 without running source code.
2. The complete base-package policy must match. Any package addition, removal
   or substitution fails closed.
3. Every update-boundary command is content-locked and assigned one of:
   reusable userland, ARM replacement, blocked hardware, blocked package path
   or deferred optional behavior.
4. A fresh installation initializes exact markers for the 87 migrations in
   the pinned source instead of executing historical upgrade scripts against a
   tree already seeded at that version.
5. Every later migration must be content-locked and individually assigned an
   ARM disposition before promotion.
6. The replacement system-package step consumes a promoted exact Arch Linux
   ARM transaction. It may not change repositories or independently select a
   kernel, firmware, device tree or boot configuration.
7. The complete candidate is applied only to a disposable image. Its hardware
   and boot manifest must compare byte for byte before G6 can pass.

The current policy audit passes for the pinned source, but it does not enable
updates or migrations. Evidence and the upstream call sequence are recorded in
[`../research/omarchy-update-audit-results.yaml`](../research/omarchy-update-audit-results.yaml).
