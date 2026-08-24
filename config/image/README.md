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

Disk IDs, FAT volume IDs and ext4 UUIDs are explicit inputs, not random values.
They must change when creating a distinct image lineage to avoid collisions.
