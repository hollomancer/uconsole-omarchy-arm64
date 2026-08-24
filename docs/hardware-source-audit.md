# Hardware source and packaging audit

Observed on **2026-08-24**. This audit compares source at immutable commits; it
does not treat a successful build or a README claim as hardware validation.

## Result

There are two credible Phase 1 hardware designs:

1. **Custom kernel:** rebuild the uConsole CM5 kernel and overlays from the
   Rex/ClockworkPi lineage as native Arch packages.
2. **Stock Raspberry Pi kernel plus board delta:** use Arch Linux ARM's
   `linux-rpi` or `linux-rpi-16k` package and build the uConsole-only drivers as
   DKMS modules, with separately packaged overlays.

The custom-kernel route has stronger exact-system history: Peter Cai and
`wdkdot/uconsole-arch` have booted Arch Linux ARM on a uConsole CM5. The DKMS
route has the cleaner long-term ownership boundary, is tested on Pi OS and
Ubuntu, and now builds reproducibly against the exact Arch headers.

Phase 1 decision: use `linux-rpi-16k` plus the pinned DKMS/overlay delta first.
Keep the custom kernel as a differential oracle and recovery fallback. The
behavioral comparison is in
[`custom-kernel-lessons.md`](custom-kernel-lessons.md); neither route changes
Omarchy.

## Arch Linux ARM kernel baseline

The Arch Linux ARM PKGBUILDs were inspected at
`a75cbace2e966c706fe02f98f538ff56f70b5d2b`.

| Package | Observed version | Pi source pin | Page/config basis | Headers |
|---|---:|---|---|---|
| `linux-rpi` | 6.18.45-1 | `65495647821026e14223095d1b0124aa3d502dec` | `bcm2711_defconfig`; conventional aarch64 page size | `linux-rpi-headers` |
| `linux-rpi-16k` | 6.18.45-1 | same | `bcm2712_defconfig`; 16 KiB | `linux-rpi-16k-headers` |

Both recipes pin the Raspberry Pi source with SHA-256 and produce matching
header packages. That makes an out-of-tree build test possible without
inventing a kernel-header package. It does not prove that every required
kernel API or config symbol is enabled.

The `.config` embedded in both exact header artifacts was also inspected. Both
enable OF overlays, GPIO, `i2c-gpio`, power-supply core, MIPI DSI, VC4/V3D,
backlight class, ALSA SoC and simple-card support. Both leave
`CONFIG_MFD_AXP20X_I2C` and `CONFIG_SND_SOC_SIMPLE_AMPLIFIER` unset, which is
consistent with the DKMS set supplying those missing board-facing pieces. The
16 KiB artifact additionally has `CONFIG_ARM64_16K_PAGES=y`. This improves the
feasibility case but is not a substitute for compiling and loading the modules.

The current community Omarchy ARM run also booted a Pi 5 directly through Pi
firmware with `linux-rpi` 6.18.45, `initramfs followkernel` and
`vc4-kms-v3d-pi5`. It observed `vc4-drm`, DRM card nodes and `renderD128`, but
had no attached display.

## `yota9/uconsole-cm5`: stock kernel plus DKMS

Pinned source: `bf7a0ab55654c96b74d013520e1196d39f66391a`.

The board delta is explicit and small compared with a full kernel fork:

| Artifact | Purpose |
|---|---|
| `panel-cwu50` | internal CWU50 panel |
| `ocp8178_bl` | panel backlight |
| `axp20x`, `axp20x-i2c`, `axp20x-regulator` | AXP228 MFD and regulator support used by the board |
| `axp20x_battery`, `axp20x_adc`, `axp20x-pek` | battery/ADC/power-key support |
| `snd-soc-simple-amplifier` | uConsole speaker amplifier control |
| `uconsole-cm5-base-overlay.dtbo` | panel, power, backlight and board wiring |
| `uconsole-audio-cm5-overlay.dtbo` | audio routing, amplifier and headphone detection |

Useful source evidence:

- all nine DKMS modules are declared `AUTOINSTALL=yes`;
- driver source files carry Linux-style SPDX/module licenses;
- the installer disables the Pi `audremap-pi5` overlay and `dtparam=spi=on`
  because GPIO8 is used by panel reset, then enables the two uConsole overlays;
- audio needs both a DT overlay and a PipeWire software-mixer policy;
- display rotation is a userspace concern after the panel binds.

Do not reuse its installer. It is apt-oriented, removes prior DKMS state, edits
`config.txt` in place and contains tolerated-error paths that do not meet this
project's safety contract. Convert the sources into an Arch package and render
boot configuration from templates instead.

Licensing remains a release blocker: the individual imported Linux driver
files identify their licenses, but no top-level license was found for the
repository's installer, overlays and project glue. Those files may be studied;
do not redistribute adapted copies until the author or repository metadata
clarifies the terms.

### Compile-spike status

The intended clean build environment is pinned as:

```text
menci/archlinuxarm:base-devel-20260819.32222611223
linux/arm64 manifest sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0
```

The initial image pull exhausted the local container store. After reclaiming
the disposable kernel checkout and running OrbStack outside the Codex sandbox,
the exact experiment encoded in
[`../research/build-uconsole-dkms.sh`](../research/build-uconsole-dkms.sh)
completed for both signed header variants.

| Header/kernel release | Modules | Overlays | ELF/vermagic | Result |
|---|---:|---:|---|---|
| `linux-rpi-headers` / `6.18.45-1-rpi` | 9/9 | 2/2 | all aarch64, exact release | PASS |
| `linux-rpi-16k-headers` / `6.18.45-1-rpi-16k` | 9/9 | 2/2 | all aarch64, exact release | PASS |

Each variant was built twice; the module and overlay hashes were identical on
the repeat. Exact artifact hashes and warning classes are recorded in
[`../research/dkms-build-results.yaml`](../research/dkms-build-results.yaml).
The harness retains the complete compiler/DT log, mounts source and headers
read-only, and promotes artifacts from a new staging directory. It does not
install anything on the host or target.

The builds emit non-fatal warnings: unused panel-driver variables, two integer
format mismatches, and four DT nodes whose unit addresses lack `reg`/`ranges`.
These should be fixed or reconciled upstream before release packaging. Build
PASS removes header compatibility as a blocker; module loading, probe order,
real panel/audio/battery behavior and kernel-update rollback remain UNKNOWN.

## Custom-kernel lineages

### `OuinOuin74/linux-clockwork-arch`

Pinned package repository: `eef4936b13e581bc91054eaae20e18fa4d2b6120`,
release v7.0.9.

Strengths:

- native Arch PKGBUILD and matching header package;
- uConsole CM5 kernel configuration, drivers and overlay are already combined;
- 16 KiB page configuration is explicit.

Its new role is an oracle rather than a competing default. It adds several
testable behaviors beyond the minimum DKMS delta: `usbhid.mousepoll=8`, a
Broadcom Wi-Fi workaround, a Pi5/CMA KMS selection, battery-profile overrides,
stricter PMIC handling and an alternate headphone amplifier driver. None is
copied automatically. Exact hypotheses are recorded in
[`../research/custom-kernel-delta.yaml`](../research/custom-kernel-delta.yaml).

Required corrections before use:

- replace MD5 checks with SHA-256 source pins;
- separate package payload from post-install edits to `config.txt`,
  `cmdline.txt` and `fstab`;
- resolve the conflicting `dwc2` instructions;
- build and sign locally rather than trusting release binaries.

### `wdkdot/uconsole-arch`

Pinned repository: `896a3acd39e0831fa4a1093ff4bb0db71d09c07d`.

This is the strongest current evidence for a flashable Arch Linux ARM CM5
system. It publishes 16 KiB and 4 KiB variants and records the kernel commit
used by its CI. However, its kernel PKGBUILD tracks a Git branch with
`SKIP` source verification unless CI injects `KERNEL_COMMIT`, does not emit a
headers subpackage, and its image profile enables `SigLevel = Optional
TrustAll`. Its images also retain default credentials. Reuse its boot-profile
knowledge and 4 KiB comparison, not its trust policy or prebuilt image.

### `TheZacillac/arch-uconsole`

Pinned repository: `c65deaada6e49104101daac8573f6809020e732d`.

Its signed-repository design and architecture-label checks are useful. Source
inspection shows that the published implementation is CM4-only; its own notes
describe CM5 as blocked on public patches at the time. It is not a CM5 kernel
candidate.

## Decision criteria

The candidate does not win because it has fewer patches or a newer version.
It wins only if all of these hold on a fresh development card:

- three cold boots with console, network and SSH;
- internal display/backlight/input/audio/battery PASS;
- V3D/V3DV acceleration with no software renderer;
- one kernel update where the candidate builds before reboot;
- a deliberate rollback to the saved kernel/modules/DT set;
- boot configuration hashes change only through the hardware package flow;
- source, package and build-log provenance is complete.
