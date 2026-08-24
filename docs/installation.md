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

The current [`bootstrap-arch.sh`](../scripts/bootstrap-arch.sh) implements only
the non-device subset of that contract. It verifies a local rootfs SHA-256,
optionally verifies the detached signature, prints the pinned next stages and
can create a **new** sparse regular `.img` file with an explicit action. It
rejects physical-device options and existing output paths. Partitioning,
mounting, rootfs extraction and SD writing remain deliberately unimplemented.

Example after the moving rootfs has been downloaded, signature-verified and
assigned an immutable SHA-256 in the build lock:

```sh
scripts/bootstrap-arch.sh \
  --rootfs downloads/ArchLinuxARM-rpi-aarch64-YYYYMMDD.tar.gz \
  --rootfs-sha256 '<64-hex-digit pinned digest>' \
  --signature downloads/ArchLinuxARM-rpi-aarch64-YYYYMMDD.tar.gz.sig \
  --plan
```

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

Research has now pinned the August 2026 rootfs and detached signature in
[`../research/phase1-inputs.yaml`](../research/phase1-inputs.yaml). Its
SHA-256 is
`f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967`,
the signature verifies under Arch Linux ARM's published build-system
fingerprint, and the archive stream is valid. Repeat signature verification in
the Linux builder; never resolve the moving `latest` URL during an image build.

Archive inspection also confirms why the rootfs is only a userspace input. It
contains CM5 DTBs, but installs generic `linux-aarch64` 7.1.6-1 and U-Boot,
uses `/dev/mmcblk0p1` in `fstab`, and includes default `root`/`alarm` accounts.
The image step must replace that boot path, render `fstab` from partition UUIDs
and rotate/lock all default credentials before first boot.

### P1.2 — Select and build the hardware package

Assumption under test: either the v7.0.9 `linux-clockwork-arch` CM5 patch set
or a stock `linux-rpi` kernel plus the `yota9/uconsole-cm5` DKMS/overlay delta
can provide a separately controlled Arch hardware layer.

1. Audit Ouin, Peter Cai and `wdkdot/uconsole-arch` packaging back to their
   common Rex kernel sources; identify rather than duplicate equivalent work.
2. Attempt a source-only Arch DKMS build of `yota9/uconsole-cm5` against the
   exact pinned `linux-rpi` headers. Clarify licensing before importing code.
3. Build the custom-kernel candidate in a clean native-aarch64 or
   full-system-QEMU Arch Linux ARM builder.
4. Convert all externally fetched inputs to SHA-256 verification.
5. Split package installation from machine mutation: the package may own kernel
   files, modules, DTBs and overlays, but not edit `fstab`, `cmdline.txt` or
   `config.txt` without an explicit image-build step.
6. Verify the kernel config, including V3D/VC4, AXP20x support, uConsole panel,
   input, audio, Broadcom radios and the observed 16 KiB page setting.
7. Diff patches against Raspberry Pi and active ClockworkPi lineages; record
   each still-required board patch.

Gate: at least one approach produces reproducible signed packages and a build
log. The same real-hardware cold-boot and kernel-update/rollback suite selects
the winner. The `dwc2` conflict and boot-file mutations are resolved before
installation.

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

## Read-only validation command

At each gate, save the complete output of the repository validator:

```sh
scripts/validate-system.sh --phase hardware
scripts/validate-system.sh --phase hyprland
scripts/validate-system.sh --phase omarchy
```

The hardware phase still reports later layers as WARN. The Hyprland and
Omarchy phases turn their respective absence into FAIL. Any OpenGL software
renderer, Vulkan software renderer, missing DRM render node or absent required
hardware remains FAIL in every phase.
