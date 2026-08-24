# Minimal first-boot system layer

This layer sits above the selected kernel/DT hardware state and below
Hyprland. It owns only first-boot identity, local/SSH access, NetworkManager,
Bluetooth, locale/timezone/keymap and their exact runtime packages.

It must not own Raspberry Pi firmware, the kernel, initramfs policy, device
tree, display orientation, Hyprland or Omarchy. Secret inputs are local files
passed at apply time and are never copied into this repository or printed.

`packages.lock` is the missing package closure resolved against the signed
August 2026 root after the selected hardware transaction, using the frozen
`core` and `extra` databases recorded in `research/image-builder-inputs.yaml`.

Run `scripts/install-base-system-packages.sh --plan` before apply. It verifies
the exact hardware-selection state and every local package's name, version,
architecture and SHA-256, then uses a single local `pacman -U` transaction. It
does not refresh or resolve a repository.

For off-target preparation of the retained integration root, use
`research/install-phase1-base-packages.sh`. It accepts only the exact
`uconsole-phase1-operator-pending-YYYYMMDD` volume namespace, runs without
network access, and proves package-transaction idempotence. The resulting root
still has the signed rootfs accounts and must not be imaged or booted until the
private configuration transaction below succeeds.

Run `scripts/configure-base-system.sh --plan` only after the package state is
present. The required operator choices are an admin account, an SSH public-key
file, a private file containing a yescrypt or SHA-512 crypt recovery hash, and
a two-letter regulatory domain. A private NetworkManager keyfile is optional;
omitting it leaves Wi-Fi enrollment for the local console. Plan mode validates
all inputs without changing the root.

The templates here are complete project-owned drop-ins. The configuration
script refuses a conflicting existing managed file, a different saved
selection, unexpected NetworkManager profiles, or pre-existing SSH host keys.
SSH host keys are intentionally left absent so the target generates a unique
identity on first boot.
