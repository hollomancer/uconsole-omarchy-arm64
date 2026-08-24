# Omarchy on uConsole CM5

This repository defines a reproducible integration path for running the Omarchy
desktop experience on a ClockworkPi uConsole with a Raspberry Pi Compute Module
5. It is not an Omarchy ISO port.

The current repository state contains research, architecture, signed rootfs
extraction, a regular-file image builder, a reproducible local hardware
package, an offline-root hardware installer, an exact minimal base-system
transaction, a version-locked minimal Hyprland installer, an inert Omarchy
source-staging transaction, and a fail-closed thin Omarchy userland package.
Five missing core Omarchy packages also have content-locked,
byte-reproducible off-target AArch64 builds. The real pinned
Arch rootfs, hardware transaction,
secret-safe base configuration, and regular-image assembly have been exercised
in isolated aarch64 Linux volumes. The content-pinned Hyprland, Omarchy shell
package and inactive user-preparation transactions also pass against a native
ARM64 clone. An 8 GiB prepared-desktop image plan passes every layer and
headroom gate, but the full image has not been allocated. All desktop work
remains off-target and hardware-gated. No script has been run against a real SD card or live system,
and the existing bootable SD card has not been touched.

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
- The configured full-root regular-image build and read-only inspection are in
  [`research/full-image-results.yaml`](research/full-image-results.yaml).
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
- The generated 148-entry package matrix and immutable audit inputs are under
  [`research/package-audit/`](research/package-audit/).
- The updater/migration call graph and ARM ownership decisions are recorded in
  [`research/omarchy-update-audit-results.yaml`](research/omarchy-update-audit-results.yaml).
- Reusable lessons from the closest Quattro ARM fork are in
  [`docs/omarchy-arm-adaptation-audit.md`](docs/omarchy-arm-adaptation-audit.md).
- The safe Phase 1 plan is in [`docs/installation.md`](docs/installation.md).
- The Phase 2 direct package set and repository snapshot are recorded in
  [`research/hyprland-package-lock.yaml`](research/hyprland-package-lock.yaml).
- The native off-target Hyprland application result is in
  [`research/hyprland-install-results.yaml`](research/hyprland-install-results.yaml).
- The first missing core package build is recorded in
  [`research/xdg-terminal-exec-inputs.yaml`](research/xdg-terminal-exec-inputs.yaml).
- The other five core local-package inputs and two-build results are in
  [`research/omarchy-core-build-inputs.yaml`](research/omarchy-core-build-inputs.yaml)
  and [`research/omarchy-core-build-results.yaml`](research/omarchy-core-build-results.yaml).
- The complete plugin/command activation policy is enforced by
  [`research/audit-omarchy-activation.sh`](research/audit-omarchy-activation.sh).
- The thin package's two-build and disposable Pacman evidence is in
  [`research/omarchy-arm64-userland-build-results.yaml`](research/omarchy-arm64-userland-build-results.yaml).
- The exact Omarchy shell closure and native offline transaction are in
  [`research/omarchy-shell-package-results.yaml`](research/omarchy-shell-package-results.yaml).
- The conflict-safe inactive home seed is recorded in
  [`research/omarchy-user-preparation-results.yaml`](research/omarchy-user-preparation-results.yaml).
- The 8 GiB prepared-but-inactive image geometry and layer gate are in
  [`research/omarchy-prepared-image-plan-results.yaml`](research/omarchy-prepared-image-plan-results.yaml).
- The storage-gated build and read-only inspection entry point is
  [`research/test-omarchy-prepared-image.sh`](research/test-omarchy-prepared-image.sh).

The validator is read-only and phase-aware:

```sh
scripts/validate-system.sh --phase hardware
scripts/validate-system.sh --phase hyprland
scripts/validate-system.sh --phase omarchy
```

It reports PASS, WARN or FAIL for all requested hardware, graphics, desktop and
package checks. Enforced desktop phases fail on unavailable GPU probes, wrong
panel orientation, missing Wayland input classes or an inactive portal.
Deterministic fixtures exercise success, software-GPU and missing-session-
evidence paths with `tests/test-validate-system.sh`.

`scripts/bootstrap-arch.sh` verifies the rootfs digest and an explicit detached
signature/keyring/fingerprint tuple, then can extract into a **new** offline
root with Linux ownership semantics. `scripts/build-image.sh` consumes exact
hardware and base-system states and creates a new MBR/FAT/ext4 regular image
with explicit partition/filesystem identities and embedded/external manifests.
It rejects an unlocked source account or cloned SSH host key as well as every
physical-device output and existing destination. The optional
`--require-omarchy-prepared` gate additionally requires the exact Hyprland,
shell-package and user-seed states and rejects any claim of session activation.

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

A 4 GiB image built from that synthetic configured clone passed filesystem
checks, read-only remount, state/account/key inspection and manifest digest
verification. The image contains integration-only credentials, was never
written to media, and is not a boot candidate.

`scripts/plan-sd-write.sh` is intentionally read-only. It verifies an image
against its manifest and a stable `/dev/disk/by-id/…` whole-disk identity, then
rejects mounted, undersized, read-only and system-root devices. There is no SD
write implementation yet.

After the real CM5 passes the hardware and accelerated-graphics gates, plan the
minimal Hyprland transaction against its mounted development root:

```sh
scripts/install-hyprland.sh --plan \
  --root /mnt/uconsole-root \
  --user yourname \
  --package-dir /path/to/hyprland-package-cache
```

This requires the exact Phase 1 base state and selected admin, then verifies a
204-package incremental closure from local files. All package payloads and
detached signatures are content-pinned; plan mode makes no repository request.
The frozen resolver, native ARM64 plan and off-target apply pass. Procedure
still prohibits applying it to development media until live hardware and
V3D/V3DV pass. The transaction installs the package set and a minimal Lua
config without enabling autologin, a display manager or UWSM, and refuses to
overwrite a different user config.

The Omarchy script currently has one intentionally narrow operation: verify a
pinned upstream archive and stage selected audit trees outside `PATH`.

```sh
scripts/install-omarchy-arm64.sh --plan \
  --root /mnt/uconsole-root \
  --user yourname \
  --source-archive /path/to/omarchy-quattro.tar.gz
```

Even in apply mode it does not expose commands, seed a home, launch Quickshell,
enable services or initialize migrations. `--activate` is rejected. This lets
the compatibility audit proceed without turning staged upstream code into an
accidental installer.

The separate thin userland candidate is also reproducibly buildable off-device:

```sh
research/audit-omarchy-activation.sh \
  --source-archive /path/to/omarchy-quattro.tar.gz

research/build-omarchy-arm64-userland.sh \
  --source-archive /path/to/omarchy-quattro.tar.gz \
  --output /new/artifact-directory
```

It locks 37 plugins, 432 commands and 141 shell/Hyprland references. The
package exposes three wrappers and retains 34 additional internal-only helpers.
Eight broad actions use documented fail-closed first-run implementations. It
contains no Hyprland defaults, home files, services, migrations, updater,
package manager or boot/hardware payload. Two network-disabled builds were
byte-identical at SHA-256
`4824a5b829cf6633e0d329307341398353fe14881c9642730e96bb7c31d93b71`.

The exact additional official runtime is a 24-package, 80,957,768-byte
transaction: 10 direct packages and 14 dependencies. It includes Quickshell,
power/clipboard/plugin support and the reviewed visual font set. Install it and
the local package as one offline, non-activating transaction:

```sh
scripts/install-omarchy-shell.sh --plan \
  --root /mnt/uconsole-root \
  --user yourname \
  --package-dir /path/to/omarchy-shell-package-cache \
  --userland-package /path/to/omarchy-arm64-userland-4.0.0.alpha-3-any.pkg.tar.xz
```

The native ARM64 apply verified all 51 required external commands, preserved
the hardware/base/Hyprland states byte for byte, and did not seed a home,
activate a session, enable UWSM or acquire hardware/update ownership.

After installing that exact package into a disposable offline root, user
preparation can be planned separately:

```sh
scripts/prepare-omarchy-user.sh --plan \
  --root /mnt/uconsole-root \
  --user yourname \
  --source-archive /path/to/omarchy-quattro.tar.gz
```

The transaction rejects conflicting user state, seeds only the reviewed shell
and Foot configurations plus immutable Tokyo Night visual state, creates 87
empty historical-migration markers without executing a migration, and leaves
Hyprland/session startup unchanged. Native ARM64 apply and byte-identical
reapply pass; live launch remains blocked until CM5 hardware and minimal
Hyprland pass.

Prospective source updates are also audit-only:

```sh
scripts/plan-omarchy-update.sh \
  --candidate-archive /path/to/omarchy-COMMIT.tar.gz \
  --candidate-commit FULL_COMMIT \
  --candidate-sha256 FULL_SHA256
```

The planner fails on any unclassified package, changed update command or new
migration. It never runs candidate code. Upstream `omarchy update` remains
blocked because it combines x86 keyrings/mirrors, rolling package selection,
Snapper/Limine assumptions, AUR updates and migrations.

The five remaining core package gaps can be built separately. First resolve
the exact 171-package signed build closure from the frozen databases, then
verify or build from the pinned source directory:

```sh
research/resolve-omarchy-core-build-closure.sh \
  --output-dir /new/empty/dependency-cache

research/build-omarchy-core-packages.sh --check \
  --source-dir /path/to/pinned-sources \
  --dependency-dir /new/empty/dependency-cache

research/build-omarchy-core-packages.sh \
  --source-dir /path/to/pinned-sources \
  --dependency-dir /new/empty/dependency-cache \
  --output /new/artifact-directory
```

The build container has no network and no device access. It validates source,
dependency and detached-signature hashes; runs package tests; checks root
ownership, native ELF architecture, fonts and Yaru contents; and writes only
to a new artifact directory. The artifacts are not installed or signed. Live
CM5/16 KiB tests and an explicit `Yaru-gray`/`Yaru-grey` policy still block
activation.

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
│   │   ├── omarchy-base-package-policy.tsv # current complete classification
│   │   ├── omarchy-command-policy.tsv    # current default-deny command surface
│   │   ├── omarchy-core.packages         # current exact first-run validation baseline
│   │   ├── omarchy-migration-baseline.lock # current no-replay baseline
│   │   ├── omarchy-plugin-policy.tsv     # current complete plugin classification
│   │   ├── omarchy-menu.jsonc            # current reduced launcher
│   │   ├── shell.json                    # current explicit plugin denylist
│   │   ├── packages.toml                 # current: substitutions and omissions
│   │   ├── omarchy-source.lock           # current: pinned Quattro archive
│   │   ├── omarchy-staged-paths.lock     # current: inert staging allowlist
│   │   ├── omarchy-update-commands.lock  # current update ownership boundary
│   │   ├── pacman/                       # future: ARM repo/drop-in policy
│   │   └── omarchy/                      # future: minimal userland overrides
│   ├── base-system/                      # current: exact Phase 1 runtime/policy inputs
│   ├── hyprland/                         # current: direct/transaction locks + Lua config
│   ├── image/                            # current: fstab/cmdline image templates
│   ├── omarchy-shell/                    # current: direct/transaction/local runtime locks
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
│   ├── audit-omarchy-base-packages.sh
│   ├── build-omarchy-core-packages.sh
│   ├── build-uconsole-dkms.sh
│   ├── build-uconsole-package.sh
│   ├── container/
│   │   ├── build-board-package-inside.sh
│   │   ├── build-dkms-inside.sh
│   │   └── build-omarchy-core-packages-inside.sh
│   ├── base-system-results.yaml
│   ├── dkms-build-results.yaml
│   ├── full-image-results.yaml
│   ├── custom-kernel-delta.yaml
│   ├── hyprland-package-lock.yaml
│   ├── hyprland-install-results.yaml
│   ├── image-builder-inputs.yaml
│   ├── omarchy-core-build-inputs.yaml
│   ├── omarchy-core-build-results.yaml
│   ├── omarchy-core-build-transaction.lock
│   ├── omarchy-update-audit-results.yaml
│   ├── omarchy-arm64-userland-build-results.yaml
│   ├── omarchy-shell-package-results.yaml
│   ├── omarchy-user-preparation-results.yaml
│   ├── omarchy-prepared-image-plan-results.yaml
│   ├── phase1-hardware-install-results.yaml
│   ├── phase1-inputs.yaml
│   ├── package-audit/                    # current generated matrix and pins
│   ├── rootfs-extraction-results.yaml
│   ├── resolve-hyprland-closure.sh
│   ├── resolve-omarchy-core-build-closure.sh
│   ├── test-full-image.sh
│   ├── test-omarchy-prepared-image.sh     # current exact 8 GiB build/inspection runner
│   ├── upstream-lock.yaml
│   └── xdg-terminal-exec-inputs.yaml
├── packaging/
│   ├── omarchy-arm64-userland/            # current thin any-architecture package
│   ├── omarchy-core/                      # current: five pinned local recipes
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
│   ├── install-omarchy-shell.sh          # current: exact inactive runtime transaction
│   ├── prepare-omarchy-user.sh            # current: conflict-safe inactive home seed
│   ├── plan-omarchy-update.sh             # current: read-only candidate audit
│   ├── plan-sd-write.sh                  # current: read-only media preflight
│   └── validate-system.sh                # current: read-only PASS/WARN/FAIL report
└── tests/
    ├── test-bootstrap-arch.sh             # current rootfs/input safety test
    ├── test-build-image.sh                # current image/device safety test
    ├── test-build-omarchy-core-packages.sh # current offline-build policy test
    ├── test-configure-base-system.sh      # current account/network policy test
    ├── test-install-base-system-packages.sh # current exact-closure test
    ├── test-install-hyprland.sh           # current package/config safety test
    ├── test-install-omarchy-arm64.sh      # current inert-staging safety test
    ├── test-install-omarchy-shell.sh      # current exact runtime-boundary test
    ├── test-install-uconsole-prerequisites.sh # current offline-closure safety test
    ├── test-install-uconsole-hardware.sh  # current transaction safety test
    ├── test-omarchy-package-policy.sh     # current complete-policy safety test
    ├── test-omarchy-prepared-image-runner.sh # current image-runner safety test
    ├── test-plan-omarchy-update.sh        # current update-boundary safety test
    ├── test-prepare-omarchy-user.sh       # current inactive-home safety test
    ├── test-validate-system.sh            # current deterministic test
    └── fixtures/                          # current captured probe fixtures
```

The planned separation is deliberate: Omarchy is not allowed to own the
Raspberry Pi boot chain, uConsole kernel, device tree, or firmware.
