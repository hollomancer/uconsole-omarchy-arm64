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

Create an optional bootstrap profile without putting its passphrase in shell
history:

```sh
scripts/create-wifi-keyfile.sh \
  --output /private/path/uconsole-bootstrap.nmconnection
```

The helper reads the SSID and passphrase from `/dev/tty`, creates a new file
directly with mode 0600 and no-clobber semantics, supports the default
WPA2/WPA3 Personal `wpa-psk` mode and
explicit WPA3-only `--key-mgmt sae`, and can mark a network `--hidden`. The
profile must remain outside the repository. NetworkManager's keyfile plugin
ignores profiles accessible to other users because they may contain plaintext
secrets, as documented in the official
[keyfile reference](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html).
The retained-root plan then feeds the profile through the target's pinned
`nmcli --offline connection modify` parser over stdin; normalized secret output
is counted and discarded rather than logged. This mode is defined by the
official [nmcli reference](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html).

The templates here are complete project-owned drop-ins. The configuration
script refuses a conflicting existing managed file, a different saved
selection, unexpected NetworkManager profiles, or pre-existing SSH host keys.
SSH host keys are intentionally left absent so the target generates a unique
identity on first boot.

On preparation hosts whose OpenSSL lacks SHA-512 crypt support (including the
current macOS LibreSSL), create the recovery input with
`scripts/create-console-password-hash.sh --output /private/path/password.hash`.
It uses the pinned, network-disabled ARM64 builder and never passes plaintext
as a process argument.

The retained Docker root is configured through
`research/configure-phase1-operator-root.sh`, not by exposing its mountpoint to
the host. Plan mode is the default and mounts the volume read-only. Apply
requires `--confirm-volume` with the exact name, runs the same configuration a
second time to prove idempotence, and automatically calls the read-only
configured-root inspector.
