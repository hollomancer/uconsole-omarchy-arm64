# Omarchy on uConsole CM5

This repository defines a reproducible integration path for running the Omarchy
desktop experience on a ClockworkPi uConsole with a Raspberry Pi Compute Module
5. It is not an Omarchy ISO port.

The current repository state is intentionally **research and architecture
only**. No installer or disk-writing script has been implemented or run. The
existing bootable SD card has not been touched.

## Status

Research snapshot: **2026-08-24**

- Upstream projects and architecture assumptions are pinned in
  [`research/upstream-lock.yaml`](research/upstream-lock.yaml).
- Closely related community attempts are assessed in
  [`docs/prior-art.md`](docs/prior-art.md).
- The integration boundary and update ownership are defined in
  [`docs/architecture.md`](docs/architecture.md).
- Candidate CM5/uConsole hardware support is mapped in
  [`docs/hardware-support.md`](docs/hardware-support.md).
- Omarchy's first ARM64 package audit is in
  [`docs/omarchy-arm64-package-matrix.md`](docs/omarchy-arm64-package-matrix.md).
- The safe Phase 1 plan is in [`docs/installation.md`](docs/installation.md).

## Proposed repository structure

The files marked `future` must not be implemented until their prerequisite
layer has passed on real hardware.

```text
.
├── README.md
├── config/
│   └── arm64-overrides/
│       ├── README.md
│       ├── packages.toml                 # future: substitutions and omissions
│       ├── pacman/                       # future: ARM repo/drop-in policy
│       └── omarchy/                      # future: minimal userland overrides
├── docs/
│   ├── architecture.md
│   ├── hardware-support.md
│   ├── installation.md
│   ├── known-issues.md
│   ├── omarchy-arm64-package-matrix.md
│   ├── prior-art.md
│   └── upstream-inventory.md
├── research/
│   ├── upstream-lock.yaml
│   └── package-audit/                    # future: generated CSV and provenance
├── scripts/
│   ├── bootstrap-arch.sh                 # future: image/rootfs construction
│   ├── install-uconsole-hardware.sh      # future: kernel/DT/firmware only
│   ├── install-hyprland.sh               # future: minimal compositor layer
│   ├── install-omarchy-arm64.sh          # future: userland only
│   └── validate-system.sh                # future: PASS/WARN/FAIL report
└── tests/
    ├── shell/                            # future: shellcheck/Bats safety tests
    └── fixtures/                         # future: package and sysfs fixtures
```

The planned separation is deliberate: Omarchy is not allowed to own the
Raspberry Pi boot chain, uConsole kernel, device tree, or firmware.
