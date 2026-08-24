# Off-target testing strategy

Hardware-free tests can eliminate many bad images, but they cannot establish
that a CM5 peripheral probes or that V3D renders. Results are split by the
claim they can support; an off-target PASS never changes a live hardware item
from UNKNOWN to PASS.

## Exact-artifact static integration

The highest-value current test uses the retained Arch Linux ARM root and the
exact files intended for first boot:

```sh
research/validate-phase1-offtarget-hardware.sh \
  --volume uconsole-phase1-operator-pending-20260824
```

The runner is network-disabled. It mounts the repository and target root
read-only, writes only to container tmpfs, and accepts no device or image
argument. It checks:

- AArch64 target binaries and the exact `linux-rpi-16k` selection state;
- application of both installed overlays to
  `bcm2712-rpi-cm5-cm5io.dtb` with the kernel header's `fdtoverlay`;
- merged panel, backlight, PMIC/battery, audio-card and amplifier nodes;
- absence of unresolved overlay fixups/phandles;
- kernel configuration for 16 KiB pages, boot storage, USB HID, VC4/V3D,
  Wi-Fi and Bluetooth;
- exact-release symbol, vermagic, license and `modprobe --dry-run` closure for
  the uConsole modules and important upstream drivers;
- initramfs root-storage, VC4/V3D and systemd/udev contents; and
- CM5 CYW43455 Wi-Fi/NVRAM and BCM4345C0 Bluetooth firmware paths.

The recorded run has zero failures and two warnings. The overlay adds 14 DTC
warning lines caused by four root nodes using `@0` without `reg`. The custom
panel, power and audio modules are available after the root filesystem mounts
but are not embedded in the initramfs, so early panel output remains unproven.
See
[`../research/phase1-offtarget-hardware-results.yaml`](../research/phase1-offtarget-hardware-results.yaml).

## Tests already possible without the uConsole

| Test | Useful claim | Current state |
|---|---|---|
| Signed root extraction and package closure | Inputs are authentic and AArch64 packages resolve | PASS |
| DKMS builds against 4 KiB and selected 16 KiB headers | Source compiles for both candidate kernel ABIs | PASS |
| Exact DTB plus installed overlay merge | References resolve and required nodes survive composition | PASS with warnings |
| `depmod` and dry-run `modprobe` | Module metadata and dependency files close for the exact release | PASS |
| Initramfs inspection | Root storage and boot userspace are present | PASS; early uConsole modules WARN |
| Regular-file image build and read-only remount | Partitioning, filesystems, boot files and policy state are coherent | PASS with synthetic identity only |
| Native AArch64 package/userland transactions | Pacman hooks, paths, command policy and package ownership behave as designed | PASS |
| Fixture-driven system validator | Hardware observations are classified PASS/WARN/FAIL deterministically | PASS |

## Emulation and headless desktop tests

QEMU's current Arm machine list documents Raspberry Pi 0 through 4 models, but
not Raspberry Pi 5, CM5 or BCM2712. Its Raspberry Pi documentation also warns
that an image for a different board will generally not boot. Therefore QEMU
cannot validate this project's Pi firmware, exact kernel/DT, V3D, DSI panel,
USB wiring, PMIC or radios. See the official
[Arm target list](https://www.qemu.org/docs/master/system/target-arm.html) and
[Raspberry Pi machine documentation](https://www.qemu.org/docs/master/system/arm/raspi.html).

A generic QEMU `virt` VM with a different compatible kernel could still test
systemd first-boot behavior, account policy, SSH and update scripts. That is a
userspace regression test, not a CM5 boot test, and duplicates much of the
current native-AArch64 container coverage. It is lower priority unless the
first-boot service path changes materially.

A disposable headless or nested Wayland session could test Hyprland config
loading, Quickshell QML, launcher/menu IPC, portals and keybinding command
resolution. A software renderer is acceptable only for that narrowly labeled
test. It must never satisfy the project's GPU gate, display geometry gate or
Phase 2 acceptance criteria.

## Evidence that remains hardware-only

- Raspberry Pi firmware boot and the running CM5 model/device tree;
- actual driver bind/probe success and boot ordering;
- internal panel timing, scanout, backlight and physical orientation;
- DRM render nodes and Broadcom V3D/V3DV acceleration;
- keyboard, trackball and power-key enumeration/behavior;
- speaker, headphone detect, amplifier enable and microphone routing;
- Wi-Fi/Bluetooth RF operation and stability;
- battery voltage/capacity/charge telemetry; and
- shutdown, suspend, wake and cold-boot reliability.

The first hardware run should therefore remain Phase 1 only. Hyprland and
Omarchy activation stay blocked until the Broadcom renderer and required
physical subsystems pass the live validator.
