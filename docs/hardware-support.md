# uConsole CM5 hardware support map

This is a **candidate map**, derived from upstream source inspection. Module
names and DT properties must be confirmed on the real unit. A candidate does
not become supported merely because the module loads.

The initial reference is the CM5 package in
[linux-clockwork-arch](https://github.com/OuinOuin74/linux-clockwork-arch),
compared with the [ClockworkPi hardware
repository](https://github.com/clockworkpi/uConsole), current Raspberry Pi
kernel sources and the stock-kernel/DKMS design audited in
[`hardware-source-audit.md`](hardware-source-audit.md).

| Subsystem | Candidate kernel module/driver | DT/firmware requirement | Package/configuration | Validation |
|---|---|---|---|---|
| Boot/model | `bcm2712` platform support | CM5 DTB, Pi firmware files, correct `config.txt` and root `PARTUUID` | pinned hardware kernel, `raspberrypi-bootloader`, `firmware-raspberrypi`; FAT boot partition | `uname -a`; `cat /proc/device-tree/model`; `cat /proc/cmdline`; `journalctl -b -p warning` |
| Console | serial/TTY and `fbcon` | console target and any required console rotation must agree with panel orientation | `systemd` getty; kernel command line only if proven necessary | `systemctl is-active getty@tty1.service`; inspect TTY orientation and early boot output |
| Internal display | `vc4`, `panel_cwu50`, `ocp8178_bl` | uConsole CM5 overlay plus `vc4-kms-v3d-pi5`; panel timing, reset/backlight GPIOs and 90° orientation | kernel/DT package; `/boot/config.txt` owned by hardware layer | `modetest -M vc4`; `ls -l /sys/class/drm`; `cat /sys/class/drm/*/status`; inspect `/sys/class/backlight` |
| GPU acceleration | `vc4`, `v3d` | full KMS overlay and render node | `mesa`, `libdrm`, `mesa-utils`, `vulkan-broadcom`, `vulkan-tools` | `lsmod`; `ls -l /dev/dri`; `glxinfo -B`; `vulkaninfo --summary`; reject `llvmpipe`, `softpipe` and `lavapipe` |
| Keyboard | `usbhid`, `hid_generic` | working CM5 USB host path; no special keyboard driver expected | `libinput`, `evtest`, udev defaults | `lsusb`; `libinput list-devices`; `evtest`; test modifiers, Fn/media keys and repeat |
| Trackball | `usbhid`, `hid_generic` | same USB composite device/host path | `libinput`, `evtest`; Hyprland pointer settings later | `libinput debug-events`; test motion, buttons and wheel |
| Wi-Fi | `brcmfmac`, `brcmutil`, `cfg80211` | correct CM5 firmware/NVRAM and regulatory domain | `firmware-raspberrypi`, `networkmanager`, upstream modprobe policy after review | `rfkill`; `iw dev`; `nmcli device`; sustained ping/throughput and reboot test |
| Bluetooth | `hci_uart`, `btbcm`, `bluetooth` (to confirm) | firmware and UART attachment appropriate to CM5 | `bluez`, `bluez-utils`, firmware package | `systemctl is-active bluetooth`; `rfkill`; `bluetoothctl show`; pair keyboard/audio device |
| SSH | network stack | none beyond working network | `openssh`; explicit `sshd_config`; key-based access before experiments | `systemctl is-active sshd`; connect from a second machine after cold boot |
| Audio | Raspberry Pi ALSA driver plus candidate `snd_soc_simple_amplifier` module | separate CM5 audio overlay, amplifier/headphone GPIO routing; do not combine with `audremap-pi5` | `alsa-utils`, `pipewire`, `pipewire-pulse`, `wireplumber`; hardware-owned boot config and audited soft-mixer policy | `aplay -l`; `arecord -l`; `wpctl status`; speaker/headphone insertion, automute and volume tests |
| Battery/AC | candidate `axp20x_battery`, `axp20x_adc`, `axp20x_pek` plus AXP MFD/I2C/regulator modules | uConsole AXP228 DT nodes and measured battery design parameters | custom kernel or locally packaged DKMS; `upower` for desktop presentation | inspect `/sys/class/power_supply/*/{type,status,capacity,voltage_now}`; `upower -e`; charge/discharge test |
| Power/suspend | SoC PM plus AXP power-key/input path | board-specific wake/power behavior | systemd-logind policy kept outside Omarchy settings until proven | controlled `systemctl suspend` only with recovery available; wake test; `journalctl -b -1` |

The uConsole keyboard firmware exposes a USB composite HID keyboard, mouse,
joystick and consumer-control device. This makes generic USB HID/libinput the
expected input path; failure is more likely a USB-host/DT problem than an
Omarchy problem.

## Graphics acceptance criteria

All of the following are required before installing Hyprland:

```sh
test "$(uname -m)" = aarch64
test -e /dev/dri/card0
test -e /dev/dri/renderD128
lsmod | grep -E '(^| )(vc4|v3d)( |$)'
glxinfo -B
vulkaninfo --summary
```

`glxinfo -B` must name the Broadcom/V3D renderer, and Vulkan must use V3DV. A
display server may be needed to run GLX; an EGL/GBM probe should be used during
console-only bring-up. `lspci` remains part of the requested report but is not
authoritative for Pi platform devices. DRM sysfs and the bound platform driver
are the useful evidence.

The later validation script will report PASS, WARN or FAIL for architecture,
kernel, page size, DT model/overlays, boot manifest, DRM nodes, bound driver,
software-renderer detection, display, audio, network, radio state, power
supplies, input devices, Hyprland and missing Omarchy packages. Unknown or
unavailable evidence must be WARN/FAIL, never silently omitted.
