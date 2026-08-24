# Omarchy on uConsole CM5

This repository defines a reproducible integration path for running the Omarchy
desktop experience on a ClockworkPi uConsole with a Raspberry Pi Compute Module
5. It is not an Omarchy ISO port.

The current repository state contains research, architecture, signed rootfs
extraction, a regular-file image builder, a reproducible local hardware
package, an offline-root hardware installer, an exact minimal base-system
transaction, a version-locked minimal Hyprland installer, and an inert Omarchy
source-staging transaction. The real pinned Arch rootfs, hardware transaction,
and secret-safe base configuration have been exercised in isolated aarch64
Linux volumes; desktop installers remain fixture-only. No script has been run
against a real SD card or live system, and the existing bootable SD card has
not been touched.

## Status

Research snapshot: **2026-08-24**

- Upstream projects and architecture assumptions are pinned in
  [`research/upstream-lock.yaml`](research/upstream-lock.yaml).
- The signed August Arch Linux ARM rootfs and Phase 1 kernel/source inputs are
  content-pinned in [`research/phase1-inputs.yaml`](research/phase1-inputs.yaml).
- Signed-root extraction evidence is in
  [`research/rootfs-extraction-results.yaml`](research/rootfs-extraction-results.yaml).
- Regular image construction inputs, failures and passing integration evidence
  are in [`research/image-builder-inputs.yaml`](research/image-builder-inputs.yaml).
- The real offline-root kernel/DKMS transaction is recorded in
  [`research/phase1-hardware-install-results.yaml`](research/phase1-hardware-install-results.yaml).
- The exact offline NetworkManager/sudo/Bluetooth closure and synthetic
  first-boot configuration run are recorded in
  [`research/base-system-results.yaml`](research/base-system-results.yaml).
- Reproducible 4 KiB/16 KiB DKMS build results are in
  [`research/dkms-build-results.yaml`](research/dkms-build-results.yaml).
- Closely related community attempts are assessed in
  [`docs/prior-art.md`](docs/prior-art.md).
- The integration boundary and update ownership are defined in
  [`docs/architecture.md`](docs/architecture.md).
- Candidate CM5/uConsole hardware support is mapped in
  [`docs/hardware-support.md`](docs/hardware-support.md).
- The competing kernel/DKMS sources and selected hardware choice are audited
  in [`docs/hardware-source-audit.md`](docs/hardware-source-audit.md).
- The custom kernel's useful deltas are retained as test hypotheses in
  [`docs/custom-kernel-lessons.md`](docs/custom-kernel-lessons.md).
- Omarchy's first ARM64 package audit is in
  [`docs/omarchy-arm64-package-matrix.md`](docs/omarchy-arm64-package-matrix.md).
- Reusable lessons from the closest Quattro ARM fork are in
  [`docs/omarchy-arm-adaptation-audit.md`](docs/omarchy-arm-adaptation-audit.md).
- The safe Phase 1 plan is in [`docs/installation.md`](docs/installation.md).
- The Phase 2 direct package set and repository snapshot are recorded in
  [`research/hyprland-package-lock.yaml`](research/hyprland-package-lock.yaml).
- The first missing core package build is recorded in
  [`research/xdg-terminal-exec-inputs.yaml`](research/xdg-terminal-exec-inputs.yaml).

The validator is read-only and phase-aware:

```sh
scripts/validate-system.sh --phase hardware
scripts/validate-system.sh --phase hyprland
scripts/validate-system.sh --phase omarchy
```

It reports PASS, WARN or FAIL for all requested hardware, graphics, desktop and
package checks. Deterministic fixtures exercise both success and software-GPU
failure paths with `tests/test-validate-system.sh`.

`scripts/bootstrap-arch.sh` verifies the rootfs digest and an explicit detached
signature/keyring/fingerprint tuple, then can extract into a **new** offline
root with Linux ownership semantics. `scripts/build-image.sh` consumes an exact
hardware-selection state and creates a new MBR/FAT/ext4 regular image with
explicit partition/filesystem identities and embedded/external manifests. Both
reject physical-device output and existing destinations.

The selected Phase 1 hardware baseline is `linux-rpi-16k` plus the pinned
`uconsole-cm5-dkms` package. The compiler/DKMS closure is also content-locked.
Build and installation are separate:

```sh
research/build-uconsole-package.sh --check \
  --headers linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz \
  --source uconsole-cm5-bf7a0ab.tar.gz

scripts/install-uconsole-hardware.sh --plan \
  --root /mnt/uconsole-root \
  --kernel linux-rpi-16k \
  --kernel-package linux-rpi-16k-6.18.45-1-aarch64.pkg.tar.xz \
  --headers-package linux-rpi-16k-headers-6.18.45-1-aarch64.pkg.tar.xz \
  --board-package uconsole-cm5-dkms-0.1.r0.gbf7a0ab-1-aarch64.pkg.tar.xz
```

The installer defaults to read-only plan mode, rejects `/` and `/dev`, and
activates the uConsole boot include only after the exact DKMS release and both
overlays are present. It generates a broad first-boot initramfs without
builder-host autodetection. On-device boot, probe and acceleration evidence is
still required.

The minimal Phase 1 system layer is split into two reviewable operations. The
first verifies and installs a 21-package, SHA-256-locked local closure; the
second consumes private local files for the recovery hash and optional Wi-Fi
connection plus a public SSH key:

```sh
scripts/install-base-system-packages.sh --plan \
  --root /mnt/uconsole-root \
  --package-dir /path/to/locked-package-cache

scripts/configure-base-system.sh --plan \
  --root /mnt/uconsole-root \
  --admin-user yourname \
  --ssh-public-key /secure/path/id_ed25519.pub \
  --console-password-hash-file /secure/path/console-password.hash \
  --reg-domain US
```

The configuration enables NetworkManager, systemd-resolved, OpenSSH and
Bluetooth; installs key-only SSH policy; and locks the source `root` and
non-admin `alarm` accounts. It never accepts plaintext password arguments or
records a Wi-Fi secret in its public state. Full package/configuration apply
and idempotent reapply pass on a disposable clone of the retained hardware
root. Operator-selected credentials have deliberately not been applied to the
retained source.

`scripts/plan-sd-write.sh` is intentionally read-only. It verifies an image
against its manifest and a stable `/dev/disk/by-id/…` whole-disk identity, then
rejects mounted, undersized, read-only and system-root devices. There is no SD
write implementation yet.

After the real CM5 passes the hardware and accelerated-graphics gates, plan the
minimal Hyprland transaction against its mounted development root:

```sh
scripts/install-hyprland.sh --plan \
  --root /mnt/uconsole-root \
  --user alarm
```

This checks all 21 direct package versions against the target's Arch Linux ARM
repositories. Apply mode installs the package set and a minimal Lua config but
does not enable autologin, a display manager or UWSM. It refuses to overwrite a
different user config. Transitive dependency versions and payload hashes are
not yet frozen, so this is a controlled bring-up transaction rather than a
complete offline package snapshot.

The Omarchy script currently has one intentionally narrow operation: verify a
pinned upstream archive and stage selected audit trees outside `PATH`.

```sh
scripts/install-omarchy-arm64.sh --plan \
  --root /mnt/uconsole-root \
  --user alarm \
  --source-archive /path/to/omarchy-quattro.tar.gz
```

Even in apply mode it does not expose commands, seed a home, launch Quickshell,
enable services or initialize migrations. `--activate` is rejected. This lets
the compatibility audit proceed without turning staged upstream code into an
accidental installer.

## Proposed repository structure

The files marked `future` must not be implemented until their prerequisite
layer has passed on real hardware. The current Hyprland installer is ready for
that gate but has not been applied to a card.

```text
.
├── README.md
├── config/
│   ├── arm64-overrides/
│   │   ├── README.md
│   │   ├── omarchy-core.packages         # current validation baseline
│   │   ├── packages.toml                 # current: substitutions and omissions
│   │   ├── omarchy-source.lock           # current: pinned Quattro archive
│   │   ├── omarchy-staged-paths.lock     # current: inert staging allowlist
│   │   ├── pacman/                       # future: ARM repo/drop-in policy
│   │   └── omarchy/                      # future: minimal userland overrides
│   ├── base-system/                      # current: exact Phase 1 runtime/policy inputs
│   ├── hyprland/                         # current: direct lock + minimal Lua config
│   ├── image/                            # current: fstab/cmdline image templates
│   └── uconsole-hardware/                # current: boot + package/prerequisite locks
├── docs/
│   ├── architecture.md
│   ├── custom-kernel-lessons.md
│   ├── hardware-source-audit.md
│   ├── hardware-support.md
│   ├── installation.md
│   ├── known-issues.md
│   ├── omarchy-arm64-package-matrix.md
│   ├── omarchy-arm-adaptation-audit.md
│   ├── prior-art.md
│   └── upstream-inventory.md
├── research/
│   ├── build-uconsole-dkms.sh
│   ├── build-uconsole-package.sh
│   ├── container/
│   │   ├── build-board-package-inside.sh
│   │   └── build-dkms-inside.sh
│   ├── base-system-results.yaml
│   ├── dkms-build-results.yaml
│   ├── custom-kernel-delta.yaml
│   ├── hyprland-package-lock.yaml
│   ├── image-builder-inputs.yaml
│   ├── phase1-hardware-install-results.yaml
│   ├── phase1-inputs.yaml
│   ├── rootfs-extraction-results.yaml
│   ├── upstream-lock.yaml
│   ├── xdg-terminal-exec-inputs.yaml
│   └── package-audit/                    # future: generated CSV and provenance
├── packaging/
│   ├── uconsole-cm5-dkms/                # current: local-evaluation PKGBUILD
│   └── xdg-terminal-exec/                # current: reproducible ARM build
├── scripts/
│   ├── bootstrap-arch.sh                 # current: signed rootfs extraction
│   ├── build-image.sh                    # current: regular image assembler
│   ├── configure-base-system.sh          # current: secret-safe offline policy
│   ├── install-base-system-packages.sh   # current: exact local runtime closure
│   ├── install-uconsole-prerequisites.sh # current: exact offline build closure
│   ├── install-uconsole-hardware.sh      # current: offline kernel/DT layer
│   ├── install-hyprland.sh               # current: minimal compositor layer
│   ├── install-omarchy-arm64.sh          # current: inert userland source stage
│   ├── plan-sd-write.sh                  # current: read-only media preflight
│   └── validate-system.sh                # current: read-only PASS/WARN/FAIL report
└── tests/
    ├── test-bootstrap-arch.sh             # current rootfs/input safety test
    ├── test-build-image.sh                # current image/device safety test
    ├── test-configure-base-system.sh      # current account/network policy test
    ├── test-install-base-system-packages.sh # current exact-closure test
    ├── test-install-hyprland.sh           # current package/config safety test
    ├── test-install-omarchy-arm64.sh      # current inert-staging safety test
    ├── test-install-uconsole-prerequisites.sh # current offline-closure safety test
    ├── test-install-uconsole-hardware.sh  # current transaction safety test
    ├── test-validate-system.sh            # current deterministic test
    └── fixtures/                          # current captured probe fixtures
```

The planned separation is deliberate: Omarchy is not allowed to own the
Raspberry Pi boot chain, uConsole kernel, device tree, or firmware.
