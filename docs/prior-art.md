# Prior art: Omarchy, ARM64, Pi 5 and uConsole CM5

Searches were run on **2026-08-24** across GitHub repositories and code,
Omarchy discussions, the ClockworkPi forum and indexed community reports.

## Conclusion

No discovered project completes the exact target stack:

```text
Arch Linux ARM + uConsole CM5 hardware + accelerated Hyprland
                + Omarchy Quattro userland + safe updates
```

The closest named project uses the older Waybar/Mako/Fuzzel style and treats
CM5 as experimental. The closest current Omarchy ARM port has run on a
Raspberry Pi 5, but only headlessly and not on uConsole hardware. Conversely,
multiple projects have working CM5/uConsole hardware and at least two report
Hyprland on its internal display. The remaining work is integration and
validation rather than invention.

GitHub code searches for `clockworkpi-uconsole-cm5` plus `omarchy`,
`omarchy-base.packages` plus `uconsole`, and Quickshell/Omarchy/uConsole found
no second complete implementation beyond the projects below.

## Direct Omarchy-on-ARM attempts

### 1. `alexisraitano-myffu/omarchy-arm` — closest current userland port

[Repository](https://github.com/alexisraitano-myffu/omarchy-arm) · `arm64`
at `579f15c699dab01e2b3b12e2c4d2503873359be9` (2026-08-23)

This is a current Omarchy Quattro fork that installs onto an existing Arch
Linux ARM machine. It explicitly targets Apple Silicon, Raspberry Pi 5 and
aarch64 VMs and does not port the ISO. That is the same high-level direction
as this project.

Useful work already present:

- preserves Arch Linux ARM's pacman servers and removes Limine/Snapper boot
  ownership on ARM;
- models replacements, AUR builds, exclusions and unavailable packages in
  manifests;
- includes a dry-run installer and tests for platform detection, architecture
  gating, package resolution, home seeding and screensaver failure;
- records real installer failures around keyrings, migrations, `/etc/skel`,
  AUR disk use, missing PulseAudio compatibility, keyboard layout and
  Omarchy's command path;
- adds a conservative Raspberry Pi Hyprland profile and installs
  `vulkan-broadcom` based on device-tree detection.

Its package counts reconcile with our audit: our 121 figure is exact-name
matches, while its 123 includes the two substitutions `nvim` → `neovim` and
the JetBrains Mono Nerd Font rename.

Limits and risks:

- its Raspberry Pi 5 run used `linux-rpi` and confirmed VC4 DRM nodes, but no
  display was attached; Hyprland was not visually validated on Pi hardware;
- it explicitly says `omarchy update` is untested on ARM;
- seven first-party Omarchy utilities still have no ARM build;
- compared locally with current upstream, it is 33 commits ahead and 21
  commits behind, changing 54 files with about 4,000 added lines. Most changes
  are new ARM code/tests, but adopting the fork wholesale would create a
  substantial rebase surface;
- AUR optional packages and Apple Silicon remain incompletely tested.

Decision: treat this as the primary Phase 3/4 reference. Reuse or upstream its
small manifests, tests and individual fixes after review; do not make its
entire fork the uConsole hardware layer.

### 2. Omarchy discussion #642 — Raspberry Pi 5 / Manjaro ARM

[“The Guide to Installing Omarchy (Hyprland) on a Raspberry Pi
5”](https://github.com/basecamp/omarchy/discussions/642), opened 2025-08-11,
reports an Omarchy v2 desktop on a Pi 5 by using a Manjaro ARM development
image, deleting the installer guard and applying several package workarounds.

It is useful historical runtime evidence but not an installation base:

- it predates Quattro and uses the removed `install-bare` flow;
- it deliberately bypasses the architecture guard;
- it starts from Manjaro rather than Arch Linux ARM;
- it does not solve CM5/uConsole hardware or update ownership;
- its optional-package advice is manual and unpinned.

Decision: mine its Pi-specific failure reports only.

### 3. `kaleaditya28897-linux/uconsole-omarchy` — exact name, different product

[Repository](https://github.com/kaleaditya28897-linux/uconsole-omarchy) ·
`main` at `25db8906ac4f43f1743846c936ecff4c6998752b` (2026-01-14)

This is the only GitHub code result directly named “uConsole Omarchy.” It
installs Arch ARM plus a custom Hyprland environment, but it is not current
Omarchy userland:

- it uses Waybar, Mako and Fuzzel rather than Quattro's Quickshell shell;
- its recommended image targets CM3/CM4/CM4S and calls CM5 experimental;
- instructions contain a placeholder clone URL and fixed default passwords;
- troubleshooting suggests enabling software rendering, which violates this
  project's GPU gate;
- it includes unrelated security-tool and Docker scope.

Decision: do not use as a base. Inspect only its small-screen/input ideas.

### 4. Other ARM Omarchy work

| Project | Proven result | Relevance |
|---|---|---|
| [`ggalancs/omarchy-arm-utm`](https://github.com/ggalancs/omarchy-arm-utm) | Omarchy 4 + ALARM + Hyprland/Quickshell in an aarch64 UTM VM; graphics fall back to software | Strong packaging/build reference, no hardware evidence |
| [`omarchy-mac/omarchy-mac`](https://github.com/omarchy-mac/omarchy-mac) | Active Quattro/Arch Linux ARM work for Asahi M1/M2, with an aarch64 repository | Useful package builds and update lessons; Apple-specific kernel/boot layer |
| [`maralcbr/omarchy-mx-mac`](https://github.com/maralcbr/omarchy-mx-mac) | Tested Quattro compatibility on a defined M1 Pro configuration | Useful validation discipline; Apple-specific |
| [`jondkinney/armarchy`](https://github.com/jondkinney/armarchy) and [Omarchy PR #1897](https://github.com/basecamp/omarchy/pull/1897) | Omarchy 3.x aarch64 adaptations | Historical package classifications only |

## Arch Linux ARM on uConsole CM5

### 5. Peter Cai's Arch Linux ARM + Sway installation

[Forum post](https://forum.clockworkpi.com/t/arch-linux-arm-for-uconsole-w-rpi-cm5/16382) ·
[technical write-up](https://typeblog.net/61092/arch-linux-arm-on-clockworkpi-uconsole-w-rpi-cm5-and-swaywm)

This is the clearest first-hand proof of the exact Arch Linux ARM/uConsole CM5
substrate. Peter Cai packaged Rex's kernel tree for ALARM, began with the ALARM
rootfs, kept `config.txt` outside package ownership, fixed a Broadcom
`wpa_supplicant` regression and ran Sway on the internal display.

Actionable lessons:

- keeping boot configuration outside kernel package ownership matches our
  architecture;
- the uConsole has no conventional Super key, so Omarchy's bindings require an
  explicit, documented remap;
- Wi-Fi must be tested against WPA2/WPA3 rather than considered working merely
  because `wlan0` exists;
- the published pacman repository is personal and unsigned, so source and
  design are inputs, not trusted binaries.

### 6. `wdkdot/uconsole-arch` — current flashable Arch CM5 images

[Repository](https://github.com/wdkdot/uconsole-arch) · `main` at
`896a3acd39e0831fa4a1093ff4bb0db71d09c07d` (2026-07-29)

This project has 55 commits, ready-to-flash CM4/CM5 ALARM images, pacman-managed
Rex kernels, boot profiles, a Broadcom Wi-Fi package, and both 16 KiB and 4 KiB
CM5 kernel packages. It is the most complete current Arch image builder found.

Do not consume it blindly: its repository uses `SigLevel = Optional TrustAll`,
images retain ALARM's default credentials, and images are built manually even
though kernel packages are automated. Its profiles, PKGBUILDs, 4 KiB option
and build scripts should be compared with our Phase 1 design.

### 7. `TheZacillac/arch-uconsole` — signed but pre-release Arch packaging

[Repository](https://github.com/TheZacillac/arch-uconsole) · `main` at
`c65deaada6e49104101daac8573f6809020e732d` (2026-04-15)

This project defines a signed `[uconsole]` pacman repository, which is a better
trust model than the unsigned alternatives. Source inspection shows the actual
package implementation is CM4-only: its own upstream-reference notes say CM5
was blocked on public patches at the time. It labels itself pre-release and
says the image builder is a future phase. Its last commit fixed a cross-build
that had stamped an ARM kernel package as x86_64, a useful warning that `CARCH`
and the built ELF architecture both need validation.

Decision: reuse signing/repository ideas, not hardware artifacts; it is not a
CM5 candidate.

### 8. `OuinOuin74/linux-clockwork-arch`

[Repository](https://github.com/OuinOuin74/linux-clockwork-arch)

Already selected as the first custom-kernel baseline in our initial research.
The additional searches confirm that it is one of several packagings of Rex's
hardware work rather than a unique driver lineage. That makes patch comparison
and convergence more important than extending its fork independently.

## Alternative hardware-layer design

### 9. `yota9/uconsole-cm5` — stock kernel plus DKMS

[Repository](https://github.com/yota9/uconsole-cm5) · `master` at
`bf7a0ab55654c96b74d013520e1196d39f66391a` (2026-07-18)

This is the most consequential new hardware finding. It keeps the Raspberry Pi
kernel updateable and supplies only uConsole-specific modules through DKMS plus
two DT overlays. It reports successful display/backlight, AXP228 battery and
power key, USB input, audio/headphone automute and software volume on Raspberry
Pi OS kernels 6.12.75/6.18.34 and Ubuntu's 7.0 raspi kernel.

Why it may be a better long-term boundary:

- hardware differences remain entirely below Arch/Omarchy userland;
- the standard Pi kernel, firmware and Mesa can follow their normal update
  path;
- its module/overlay list is a precise definition of the board delta;
- the same design could become an Arch DKMS package instead of an apt script.

What remains unknown:

- its nine modules and two overlays now build reproducibly against current
  Arch Linux ARM `linux-rpi` and `linux-rpi-16k` headers, but have not been
  loaded on an Arch/uConsole system;
- DKMS ABI/build failures can turn a routine kernel update into a no-display
  boot, so a known-good kernel and pre-upgrade build gate are still necessary;
- the repository has no detected top-level license metadata. Individual Linux
  driver sources retain their upstream licenses, but project glue must not be
  copied until licensing is clear;
- an out-of-tree driver set carries its own forward-port burden.

Decision: add a source-only DKMS feasibility spike before freezing the Phase 1
kernel design. Compare it against the monolithic Rex/Ouin package on the same
ALARM rootfs; select one only after cold-boot and kernel-update tests.

### 10. `nixos-uconsole/nixos-uconsole`

[Repository](https://github.com/nixos-uconsole/nixos-uconsole) · experimental
CM5 support

Although it is not Arch, its declarative image build confirms the same CWU50
panel, AXP228, OCP8178 and audio patch set. It also exposes CM5 overlay
parameters such as `no_rp1eth`, `no_sound_switch` and battery design capacity,
and reports a power-button sleep/shutdown policy. Use it to cross-check DT and
power semantics, not as a package source.

## Hyprland on the actual CM5/uConsole display

### 11. `AleReb/uconsole-hyprland-dotfiles`

[Repository](https://github.com/AleReb/uconsole-hyprland-dotfiles) · `main` at
`a3c17f1761a548d089ed28b3204961e98410accc` (2026-07-23)

This is a Debian 13 Hyprland setup explicitly tuned for the CM5 uConsole. It
maps the keyboard's `open` key to Super with `keyd`, configures the rotated
internal display, and selects the correct DRM card with `AQ_DRM_DEVICES` at
session startup. The author reports that persistent polling, `DRI_PRIME` and
`WLR_RENDER_DRM_DEVICE` caused high CPU, so HDMI/DSI switching uses udev events
and a deliberate compositor restart.

Decision: carry its input mapping and DRM-device observations into Phase 2
test cases. Do not import its Waybar/Wofi/Dunst desktop over Quattro.

A separate [CM5 user report](https://www.reddit.com/r/ClockworkPi/comments/1tcimp3/hyprland_feels_fantastic_on_uconsole/)
confirms Hyprland on Rex's Debian Trixie image and the internal display, with
ABXY remapping tested through `wev`. It is encouraging hardware evidence, not
a reproducible build or GPU validation log.

### 12. `Pimarchy`

[`raythurman2386/pimarchy`](https://github.com/raythurman2386/pimarchy) builds
an Omarchy-inspired Hyprland desktop on Raspberry Pi OS Lite. It has an
installer, uninstaller and validator, but uses Waybar/Rofi/Mako and its own
theme rather than Omarchy Quattro. It is useful for Pi OS packaging and
validation patterns only.

## Resulting investigation order

Before implementing Phase 1 scripts:

1. Diff `alexisraitano-myffu/omarchy-arm` against its upstream base and extract
   the package manifests, test cases and documented failure modes that remain
   valid on current Quattro.
2. Compare three Arch hardware packages from source: Ouin's v7.0.9 package,
   `wdkdot/uconsole-arch`, and Peter Cai's design. Map all three back to Rex's
   kernel commits so duplicated patches are visible.
3. Reproduce the passing `yota9/uconsole-cm5` builds in a disposable ALARM
   environment, resolve licensing/warnings, then determine whether current
   `linux-rpi` can load its exact modules. Do not install it on the working
   card.
4. Choose custom kernel versus stock kernel + DKMS using the same acceptance
   tests: cold boot, internal display, audio, battery, radios, 4K/16K page size
   and one kernel upgrade/rollback.
5. Add `keyd`/Super-key and `AQ_DRM_DEVICES` cases from the real uConsole
   Hyprland work to Phase 2 validation.
6. Keep the Omarchy compatibility layer separate from whichever hardware
   approach wins.
