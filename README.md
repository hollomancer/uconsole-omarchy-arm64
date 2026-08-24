# Omarchy on uConsole CM5

This repository defines a reproducible integration path for running the Omarchy
desktop experience on a ClockworkPi uConsole with a Raspberry Pi Compute Module
5. It is not an Omarchy ISO port.

The current repository state contains research, architecture, read-only
validation, a reproducible local hardware package, an offline-root hardware
installer and a version-locked minimal Hyprland installer. Installer apply
mode has been exercised only against deterministic fixtures. No script has
been run against a real SD card or live system, and the existing bootable SD
card has not been touched.

## Status

Research snapshot: **2026-08-24**

- Upstream projects and architecture assumptions are pinned in
  [`research/upstream-lock.yaml`](research/upstream-lock.yaml).
- The signed August Arch Linux ARM rootfs and Phase 1 kernel/source inputs are
  content-pinned in [`research/phase1-inputs.yaml`](research/phase1-inputs.yaml).
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

The validator is read-only and phase-aware:

```sh
scripts/validate-system.sh --phase hardware
scripts/validate-system.sh --phase hyprland
scripts/validate-system.sh --phase omarchy
```

It reports PASS, WARN or FAIL for all requested hardware, graphics, desktop and
package checks. Deterministic fixtures exercise both success and software-GPU
failure paths with `tests/test-validate-system.sh`.

`scripts/bootstrap-arch.sh` is currently a safe bootstrap scaffold. It verifies
a pinned local rootfs, optionally verifies its detached signature, prints the
image-build stages and can create a new sparse regular image. It cannot
partition, mount or write a physical device.

The selected Phase 1 hardware baseline is `linux-rpi-16k` plus the pinned
`uconsole-cm5-dkms` package. Build and installation are separate:

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
overlays are present.

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
│   │   ├── packages.toml                 # future: substitutions and omissions
│   │   ├── pacman/                       # future: ARM repo/drop-in policy
│   │   └── omarchy/                      # future: minimal userland overrides
│   ├── hyprland/                         # current: direct lock + minimal Lua config
│   └── uconsole-hardware/                # current: boot fragment + package lock
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
│   ├── dkms-build-results.yaml
│   ├── custom-kernel-delta.yaml
│   ├── hyprland-package-lock.yaml
│   ├── phase1-inputs.yaml
│   ├── upstream-lock.yaml
│   └── package-audit/                    # future: generated CSV and provenance
├── packaging/
│   └── uconsole-cm5-dkms/                # current: local-evaluation PKGBUILD
├── scripts/
│   ├── bootstrap-arch.sh                 # current: verified image-only scaffold
│   ├── install-uconsole-hardware.sh      # current: offline kernel/DT layer
│   ├── install-hyprland.sh               # current: minimal compositor layer
│   ├── install-omarchy-arm64.sh          # future: userland only
│   └── validate-system.sh                # current: read-only PASS/WARN/FAIL report
└── tests/
    ├── test-bootstrap-arch.sh             # current image safety test
    ├── test-install-hyprland.sh           # current package/config safety test
    ├── test-install-uconsole-hardware.sh  # current transaction safety test
    ├── test-validate-system.sh            # current deterministic test
    └── fixtures/                          # current captured probe fixtures
```

The planned separation is deliberate: Omarchy is not allowed to own the
Raspberry Pi boot chain, uConsole kernel, device tree, or firmware.
