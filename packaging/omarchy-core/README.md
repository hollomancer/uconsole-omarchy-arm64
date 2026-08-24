# Core Omarchy local packages

These five recipes close the core exact-name gaps left after resolving the
Omarchy Quattro base list against the frozen Arch Linux ARM repositories. They
are deliberately separate from the future Omarchy userland package and from
all uConsole hardware packages.

| Package | Pinned version | Package architecture | Remaining live gate |
|---|---:|---|---|
| `omacalc` | 0.2.2-2 | aarch64 | Qt and 16 KiB runtime |
| `omacut` | 0.4.0-2 | aarch64 | portal, clipboard and 16 KiB runtime |
| `ttf-ia-writer` | 20181225-2 | any | font discovery |
| `ttfx` | 0.3.2-3 | aarch64 | session and 16 KiB runtime |
| `yaru-icon-theme` | 26.04.5.1ubuntu-3 | any | theme discovery and gray/grey policy |

Do not run `makepkg` ad hoc on the uConsole. The supported research path is
`research/resolve-omarchy-core-build-closure.sh` followed by
`research/build-omarchy-core-packages.sh`. It uses content-pinned sources, a
171-package signed dependency transaction, a digest-pinned AArch64 builder,
and no container network or device access. It does not install anything.

The `ttfx` patch changes only the architecture condition in one golden test;
runtime code is untouched. The Yaru recipe enables GTK at build time because
the pinned upstream icons-only Meson path references GTK-created color
targets, then removes `/usr/share/themes` and verifies the package remains an
icon-only split.

Exact source and package hashes, test results, warnings and unproven behavior
are recorded in `research/omarchy-core-build-inputs.yaml` and
`research/omarchy-core-build-results.yaml`. Packages must be rebuilt on native
ARM, live-tested on the CM5, and signed before any target repository consumes
them.
