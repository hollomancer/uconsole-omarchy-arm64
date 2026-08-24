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

## Safety contract

`build-image.sh` creates a regular image and has no physical-device code.
Writing a block device remains a separate future operation and will require all
of the following:

- `--device /dev/disk/by-id/<exact-device>` (not a mutable `/dev/sdX` alone);
- `--write-device`;
- `--i-understand-this-erases-the-device`;
- an unmounted device that is not the running system disk;
- a displayed model/serial/size confirmation;
- a saved pre-write partition report.

The script must refuse empty variables, globbed devices, partitions instead of
whole devices, mounted targets, and targets whose identity changes between
inspection and write. Destructive commands will never be implicit or hidden.

The current [`bootstrap-arch.sh`](../scripts/bootstrap-arch.sh) verifies a
local rootfs SHA-256 and requires an explicit detached signature, trusted
keyring and exact signer fingerprint before extraction. Extraction is
Linux/root-only and accepts only a new offline-root destination.

[`build-image.sh`](../scripts/build-image.sh) creates a new regular image,
partitions it with a deterministic MBR, formats FAT32/ext4, copies the prepared
root, renders PARTUUID-based boot/fstab configuration, runs both filesystem
checks and publishes embedded/external manifests. Its pinned aarch64 fixture
integration test passes. [`plan-sd-write.sh`](../scripts/plan-sd-write.sh) is a
read-only Linux physical-media preflight; it deliberately has no write action.

Example after the moving rootfs has been downloaded, signature-verified and
assigned an immutable SHA-256 in the build lock:

```sh
scripts/bootstrap-arch.sh \
  --rootfs downloads/ArchLinuxARM-rpi-aarch64-YYYYMMDD.tar.gz \
  --rootfs-sha256 '<64-hex-digit pinned digest>' \
  --signature downloads/ArchLinuxARM-rpi-aarch64-YYYYMMDD.tar.gz.sig \
  --keyring build/archlinuxarm.gpg \
  --signer-fingerprint 68B3537F39A313B3E574D06777193F152BDBE6A6 \
  --root-tree build/arch-root \
  --extract-root
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
fingerprint, and the archive stream is valid. The exact archive has now been
verified with `gpgv` and extracted in the pinned aarch64 Linux container while
preserving numeric ownership. Evidence and all failed assumptions are in
[`../research/rootfs-extraction-results.yaml`](../research/rootfs-extraction-results.yaml).
Never resolve the moving `latest` URL during an image build.

Archive inspection also confirms why the rootfs is only a userspace input. It
contains CM5 DTBs, but installs generic `linux-aarch64` 7.1.6-1 and U-Boot,
uses `/dev/mmcblk0p1` in `fstab`, and includes default `root`/`alarm` accounts.
The image step must replace that boot path, render `fstab` from partition UUIDs
and rotate/lock all default credentials before first boot.

### P1.2 — Build the selected hardware package

Decision: use Arch Linux ARM `linux-rpi-16k` plus the pinned
`yota9/uconsole-cm5` DKMS/overlay delta. The v7.0.9 custom kernel remains a
differential oracle and recovery fallback.

1. Audit Ouin, Peter Cai and `wdkdot/uconsole-arch` packaging back to their
   common Rex kernel sources; identify rather than duplicate equivalent work.
2. Reproduce the now-passing source-only builds of `yota9/uconsole-cm5`
   against the exact pinned `linux-rpi` and `linux-rpi-16k` headers. Clarify
   licensing before importing code, then test loading only on development
   media.
3. Preserve the custom kernel's known boot, Wi-Fi, HID, KMS, battery and audio
   differences as individually testable fallback hypotheses.
4. Convert all externally fetched inputs to SHA-256 verification.
5. Split package installation from machine mutation: the package may own kernel
   files, modules, DTBs and overlays, but not edit `fstab`, `cmdline.txt` or
   `config.txt` without an explicit image-build step.
6. Verify the kernel config, including V3D/VC4, AXP20x support, uConsole panel,
   input, audio, Broadcom radios and the observed 16 KiB page setting.
7. Diff patches against Raspberry Pi and active ClockworkPi lineages; record
   each still-required board patch.

Gate: the selected approach produces reproducible signed packages and a build
log. The real-hardware cold-boot and kernel-update/rollback suite passes. The
`dwc2` contradiction is treated as an input-device test, and no package hook
mutates machine identity or partition configuration.

#### Current package and installer interface

The local-evaluation board package is built from the pinned source archive in
the pinned aarch64 container:

```sh
research/build-uconsole-package.sh \
  --headers /path/to/linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz \
  --source /path/to/uconsole-cm5-bf7a0ab.tar.gz \
  --output /new/output/directory
```

Two clean builds produced the same
`uconsole-cm5-dkms-0.1.r0.gbf7a0ab-1-aarch64.pkg.tar.xz` SHA-256:
`a9058969381e40b6fc4edec9082aa628b2ba7c89504eeecdb0a7cd12a8a6718d`.
The package is not yet signed and must not be redistributed while upstream
overlay/project-glue licensing is unresolved.

Always run the hardware installer in plan mode first:

```sh
scripts/install-uconsole-hardware.sh --plan \
  --root /mnt/uconsole-root \
  --kernel linux-rpi-16k \
  --kernel-package /path/to/linux-rpi-16k-6.18.45-1-aarch64.pkg.tar.xz \
  --headers-package /path/to/linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz \
  --board-package /path/to/uconsole-cm5-dkms-0.1.r0.gbf7a0ab-1-aarch64.pkg.tar.xz
```

Apply mode accepts only an offline Arch Linux ARM filesystem root. It requires
`dkms`, `gcc` and `make` to be installed in that root and a functioning native
aarch64 or binfmt `arch-chroot` environment. It removes only installed
`linux-aarch64`, `linux-aarch64-headers` and `uboot-raspberrypi` conflicts,
then installs the locked package set. If Pacman or DKMS fails, it exits before
activating the uConsole boot include. The exact nine-package build closure is
locked in `config/uconsole-hardware/prerequisites.lock` and installed without
mirror resolution by `install-uconsole-prerequisites.sh`.

The real signed offline root has passed this transaction. The generic kernel
and U-Boot packages were removed, DKMS installed all board modules for
`6.18.45-1-rpi-16k`, both overlays were installed, and a broad first-boot
initramfs was generated without builder-host hardware autodetection. See
[`../research/phase1-hardware-install-results.yaml`](../research/phase1-hardware-install-results.yaml).
This is build evidence, not a claim that the CM5 has booted it.

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

The regular-image fixture passes this gate, including exact MBR geometry,
filesystem IDs, fsck, read-only remount, rendered boot references and both
manifests. The full hardware root has not been promoted to a development image
because the retained source deliberately does not contain operator
credentials; P1.4 has been proven only on a disposable clone.

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

The implementation now uses NetworkManager as the single network owner and is
split so package installation cannot accidentally consume secret inputs. First
stage the exact packages named in `config/base-system/packages.lock`, then run:

```sh
scripts/install-base-system-packages.sh --plan \
  --root /mnt/uconsole-root \
  --package-dir /path/to/locked-package-cache

scripts/install-base-system-packages.sh --apply \
  --root /mnt/uconsole-root \
  --package-dir /path/to/locked-package-cache

scripts/configure-base-system.sh --plan \
  --root /mnt/uconsole-root \
  --admin-user yourname \
  --ssh-public-key /secure/path/id_ed25519.pub \
  --console-password-hash-file /secure/path/console-password.hash \
  --reg-domain US
```

Add `--wifi-keyfile /secure/path/bootstrap.nmconnection` only when Wi-Fi must
associate before the first local login. The file must be a private
NetworkManager WPA-PSK connection; no secret should be placed in the repository
or command line. If Wi-Fi is omitted, enroll it from the local console.

Generate the console recovery hash into a private file on the preparation host
without putting plaintext in process arguments:

```sh
umask 077
read -r -s -p 'Local console recovery password: ' UCONSOLE_RECOVERY_PASSWORD
printf '\n'
printf '%s\n' "$UCONSOLE_RECOVERY_PASSWORD" | openssl passwd -6 -stdin > /secure/path/console-password.hash
unset UCONSOLE_RECOVERY_PASSWORD
chmod 0600 /secure/path/console-password.hash
```

After reviewing plan output, rerun the same configuration arguments with
`--apply`. Apply creates or validates the admin, installs its public key, locks
`root` and the non-admin source `alarm` account, disables systemd-networkd
activation, enables NetworkManager/systemd-resolved/sshd/Bluetooth, generates
the locale and writes non-secret selection state. It refuses conflicting
policy and leaves SSH host keys absent for unique generation on the device.

The exact 21-package closure and this policy pass apply plus idempotent reapply
on a disposable native-aarch64 clone of the real retained hardware root. See
[`../research/base-system-results.yaml`](../research/base-system-results.yaml).
The retained source remains unchanged. Before promoting it, the operator must
still select the admin name, SSH public key, regulatory domain, recovery-hash
file, and whether to provide a private bootstrap Wi-Fi keyfile.

### P1.5 — Write and boot the fresh SD

Assumption: the produced image targets the identified development card only.

1. Re-run the read-only device inventory and compare model/serial/size.
2. Run `scripts/plan-sd-write.sh` and save its exact image hash plus target
   model/serial/size report.
3. Invoke the future separately reviewed writer with explicit destructive
   flags. Capture the exact command and image SHA-256 in the experiment log.
4. Verify the written partition table and sampled image checksum before eject.
5. Boot with serial logging if available. Preserve the full first-boot journal.
6. Repeat three cold boots after the first successful configuration.

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

Only after Phase 1 passes, plan the smallest ALARM Hyprland set:

```sh
scripts/install-hyprland.sh --plan \
  --root /mnt/uconsole-root \
  --user alarm
```

The script requires the exact `linux-rpi-16k`/uConsole hardware-selection
state, verifies all 21 direct package versions against the target's sync
databases, and reports the one user config it would create. Plan mode writes
nothing. Inspect that output and the saved live hardware validation before
changing `--plan` to `--apply`.

Apply mode installs Hyprland, Aquamarine, portals, Foot, PipeWire/WirePlumber,
Mesa/V3DV and the requested input/graphics diagnostics. It installs
`~/.config/hypr/hyprland.lua` only when that path is absent or already exactly
matches the repository template. A different config is a hard error. It does
not enable a display manager, autologin or UWSM.

The default config covers both connector names observed in related uConsole
work: DSI-1 and DSI-2 use transform 3, while the fallback output rule leaves
external displays unrotated. Blur, shadows and animations are disabled during
bring-up. Log in at a local TTY and start the first session explicitly:

```sh
start-hyprland
```

Inside the session, save the exact requested evidence:

```sh
uname -m
uname -r
getconf PAGESIZE
glxinfo -B
vulkaninfo --summary
lsmod
lspci -nnk
ls -l /dev/dri
hyprctl systeminfo
hyprctl monitors all
libinput list-devices
wpctl status
```

Then run `scripts/validate-system.sh --phase hyprland`. Any llvmpipe, softpipe
or lavapipe result stops progression. Do not add Omarchy until the native panel
mode/orientation, keyboard and trackball have been exercised in Wayland and the
Hyprland validator exits successfully.

The current lock proves direct repository selection, not a fully offline
dependency closure. Before producing a distributable image, archive and hash
the resolved package payloads and all transitive versions, then sign the local
repository metadata.

## Inert Omarchy source audit

The next repository operation is deliberately not Omarchy activation. Given
the pinned Quattro archive, the script can verify and stage selected source
trees for audit:

```sh
scripts/install-omarchy-arm64.sh --plan \
  --root /mnt/uconsole-root \
  --user alarm \
  --source-archive /path/to/omarchy-quattro.tar.gz
```

The locked archive is commit `d99d4fc6de0bc99d48c9935724fa19d7fb41ae54`,
version-file value `4.0.0.alpha`, SHA-256
`3b60bb6d5694478963c167571457ee266cdba1e7791395a80f2f26074d72d6eb`
and size 70,979,927 bytes. Apply mode stages only the allowlisted audit paths
under `/usr/share/uconsole-omarchy-arm64/upstream/<commit>`, generates a
per-file manifest, and records `activation=blocked`.

It does not create `/usr/bin/omarchy`, modify `PATH`/`OMARCHY_PATH`, copy a
config into the target home, enable UWSM/SDDM, run Quickshell, initialize
migration markers, install packages or touch `/boot`. A modified staged tree
is a hard error on rerun. There is no implemented activation flag.

This staging step lets command consumers, QML dependencies, themes and user
defaults be audited against one immutable source without bypassing G3/G4. The
actual core-userland activation will be a separate transaction after the real
hardware gates pass and the command/package allowlists close.

### First ARM-built Omarchy dependency

`xdg-terminal-exec` is core terminal-dispatch infrastructure and has no current
ALARM sync-repository package. Build it off-device with the pinned source and
exact hashed `scdoc`, `bats` and `parallel` inputs:

```sh
research/build-xdg-terminal-exec.sh --check \
  --source /path/to/xdg-terminal-exec-v0.14.3.tar.gz \
  --scdoc /path/to/scdoc-1.11.5-1-aarch64.pkg.tar.xz \
  --bats /path/to/bats-1.14.0-1-any.pkg.tar.xz \
  --parallel /path/to/parallel-20260722-1-any.pkg.tar.xz
```

Two builds produced byte-identical
`xdg-terminal-exec-0.14.3-1-any.pkg.tar.xz` payloads with SHA-256
`1359a9bb531c4014a1324d9fdefc5c8350e39c587be2592eacb56eda352cca4d`.
Twenty-three tests passed and the Turkish-collation test skipped because that
locale is absent from the minimal builder. One build printed an intermittent
fakeroot warning under emulation; the other did not, and both archives contain
root-owned files. Rebuild on native ARM before signing and installation.

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
