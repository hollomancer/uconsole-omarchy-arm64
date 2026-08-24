# Installation and Phase 1 plan

No command in this document has been executed against an SD card. Phase 1 must
use a new development card; the known-working card remains removed, labeled and
unchanged.

## First command

In the Linux preparation environment, after inserting only the fresh
development SD card, run:

```sh
lsblk -o NAME,PATH,MODEL,SERIAL,TRAN,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
```

This is deliberately read-only. It establishes the device path, transport,
model, serial, size, existing filesystems and mount state before any script is
allowed to accept a destructive target. On a macOS preparation host, obtain the
same evidence with `diskutil list external physical`, but the reproducible image
builder is planned for Linux because Arch ownership, loop-device and chroot
semantics must match the target tooling.

## Safety contract for future scripts

`bootstrap-arch.sh` will build a regular image file by default. Writing a block
device will require all of the following:

- `--device /dev/disk/by-id/<exact-device>` (not a mutable `/dev/sdX` alone);
- `--write-device`;
- `--i-understand-this-erases-the-device`;
- an unmounted device that is not the running system disk;
- a displayed model/serial/size confirmation;
- a saved pre-write partition report.

The script must refuse empty variables, globbed devices, partitions instead of
whole devices, mounted targets, and targets whose identity changes between
inspection and write. Destructive commands will never be implicit or hidden.

## Concrete Phase 1 implementation plan

### P1.0 — Establish recovery and provenance

Assumption: development can proceed without risking the working system.

1. Remove and label the working SD card. Do not use it as an input to automated
   tooling.
2. Document serial console pinout/access or prove reliable SSH plus a second
   machine before display experiments.
3. Record the fresh SD identity with the command above.
4. Record CM5 EEPROM/firmware version when first boot becomes possible.

Gate: G0 in `architecture.md` passes.

### P1.1 — Pin build inputs

Assumption: the generic Arch Linux ARM Raspberry Pi aarch64 rootfs is a valid
userspace foundation when paired with a CM5/uConsole kernel.

1. Download the current `ArchLinuxARM-rpi-aarch64-latest.tar.gz` and its
   signature from an official mirror.
2. Verify the signature against the Arch Linux ARM signing key, compute SHA-256,
   and replace the moving `latest` URL in the build lock with a content digest
   and archived local filename.
3. Pin the kernel/patch repository commit and every source tarball hash.
4. Snapshot the ALARM sync database hashes used for the build.

Gate: the build can be reproduced without silently advancing any input.

### P1.2 — Build the hardware kernel package

Assumption: the v7.0.9 `linux-clockwork-arch` CM5 patch set is sufficient for a
first boot and is reviewable as an Arch package.

1. Build in a clean native-aarch64 or full-system-QEMU Arch Linux ARM builder.
2. Convert all externally fetched inputs to SHA-256 verification.
3. Split package installation from machine mutation: the package may own kernel
   files, modules, DTBs and overlays, but not edit `fstab`, `cmdline.txt` or
   `config.txt` without an explicit image-build step.
4. Verify the kernel config, including V3D/VC4, AXP20x support, uConsole panel,
   input, audio, Broadcom radios and the observed 16 KiB page setting.
5. Diff patches against Raspberry Pi and active ClockworkPi lineages; record
   each still-required board patch.

Gate: a reproducible signed package and build log exist. The `dwc2` conflict and
boot-file mutations are resolved before installation.

### P1.3 — Construct an image file, not the SD card

Assumption: Pi firmware can boot a conventional FAT boot plus ext4 root layout.

1. Allocate a sparse image under `build/`, then create a FAT32 boot partition
   and ext4 root partition inside it.
2. Extract the verified ALARM rootfs with numeric owners preserved.
3. Install the locally built hardware kernel package inside an aarch64 execution
   environment so package hooks run with target semantics.
4. Populate the FAT partition with pinned firmware, DTBs, overlays, kernel and
   initramfs.
5. Generate `config.txt`, `cmdline.txt`, `fstab` and root `PARTUUID` from
   version-controlled templates. Do not use Limine, Snapper or Omarchy config.
6. Generate `manifest.json` containing partition UUIDs and hashes of every boot
   file.

Gate: the image mounts read-only and its package database, ownership, boot
references and manifest are internally consistent.

### P1.4 — Configure the minimal system

Assumption: boot, networking and recovery can be proven without a graphical
desktop.

Install only the minimum for locale/time, NetworkManager, Wi-Fi firmware,
OpenSSH, sudo, diagnostics and hardware validation. Create a non-root admin
user, use SSH keys, lock password SSH login, set the regulatory domain, and
enable exactly one network manager.

No Hyprland, display manager, Omarchy package or AUR helper is introduced.

Gate: configuration is visible in the mounted image and SSH credentials have a
documented recovery path.

### P1.5 — Write and boot the fresh SD

Assumption: the produced image targets the identified development card only.

1. Re-run the read-only device inventory and compare model/serial/size.
2. Invoke the future explicit write flags. Capture the exact command and image
   SHA-256 in the experiment log.
3. Verify the written partition table and sampled image checksum before eject.
4. Boot with serial logging if available. Preserve the full first-boot journal.
5. Repeat three cold boots after the first successful configuration.

Gate: console, networking and key-based SSH pass three cold boots.

### P1.6 — Validate hardware in dependency order

Test in this order so that failures remain in the correct layer:

1. model/DT, kernel, modules and page size;
2. USB keyboard and trackball;
3. internal panel, backlight, native mode and orientation;
4. VC4/V3D DRM nodes and accelerated EGL/OpenGL/Vulkan;
5. Wi-Fi and Bluetooth;
6. ALSA/PipeWire speaker and headphone behavior;
7. battery/AC reporting during charge and discharge;
8. power button behavior; suspend only with recovery available.

For every test, record finding, assumption, smallest change, exact command,
validation output and failure. A failure produces a new hardware-layer commit;
it does not produce an Omarchy workaround.

Gate: all required hardware is PASS and GPU acceleration is not software.
Suspend may remain WARN only when the actual platform limitation and safe power
behavior are documented.

## Phase 2 handoff

Only after Phase 1 passes, install the smallest ALARM Hyprland set: Hyprland,
Aquamarine, UWSM, xdg-desktop-portal-hyprland, a terminal and diagnostic tools.
Run the requested `uname`, `glxinfo`, `vulkaninfo`, `lsmod`, `lspci`, `/dev/dri`
and `hyprctl systeminfo` checks before any Omarchy userland enters the image.
