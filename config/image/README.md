# Phase 1 image identity

These templates are rendered only into a new regular image. They never target
a physical device and never mutate the prepared root tree.

The image uses an MBR partition table because Raspberry Pi firmware expects a
simple FAT boot partition. An explicit disk identifier makes PARTUUIDs stable:

- boot: `<disk-id>-01`
- root: `<disk-id>-02`

`fstab.template` and `cmdline.txt.template` are rendered from those values.
The selected `linux-rpi-16k` package supplies `config.txt`; the hardware
installer appends its one managed include. The image builder verifies that
package-owned base plus managed include instead of replacing it.

The builder also requires the completed exact base-system package and
configuration states. It verifies locked source accounts, the non-root admin,
key-only SSH policy, locale/radio/network selections and the absence of SSH
host keys. A hardware-only root with Arch Linux ARM's source credentials is a
hard failure, even in plan mode.

Disk IDs, FAT volume IDs and ext4 UUIDs are explicit inputs, not random values.
They must change when creating a distinct image lineage to avoid collisions.
The ext4 label is `uconsole-root`; account names never determine filesystem
identity.
