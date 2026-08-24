# uConsole CM5 hardware configuration

This directory belongs to the hardware layer, not to the Omarchy ARM override
layer. `config.txt.fragment` is included by the stock Arch Linux ARM Raspberry
Pi boot configuration after the hardware package is installed.

The fragment deliberately does not select a kernel, root partition, initramfs,
display transform or user session. The official `linux-rpi-16k` package owns
the kernel/KMS/CM5 USB-host defaults; the image builder owns PARTUUIDs; and
Hyprland owns the Wayland transform.

Active `dtparam=spi=on` and `dtoverlay=audremap-pi5` lines are hard conflicts.
The hardware installer reports them and stops instead of rewriting unrelated
boot configuration.

`packages.lock` is the runtime authority for the exact official kernel,
headers and local board-package archives. It is deliberately simple data, not
a sourced shell fragment. Version bumps replace the whole tested set in one
commit.
