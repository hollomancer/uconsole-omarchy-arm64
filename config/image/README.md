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

`--require-omarchy-prepared` is an opt-in later-layer gate. It additionally
requires the exact Hyprland, Omarchy shell and user-preparation states plus the
reviewed user configuration hashes and initial theme links. It rejects UWSM or
session activation; satisfying this gate prepares an image source but does not
enable the desktop. Build mode records `prepared-inactive` or `not-required` in
both the embedded selection state and external manifest.

Disk IDs, FAT volume IDs and ext4 UUIDs are explicit inputs, not random values.
They must change when creating a distinct image lineage to avoid collisions.
The ext4 label is `uconsole-root`; account names never determine filesystem
identity.

For the retained real Phase 1 root, `research/build-phase1-image.sh` is the
bounded host handoff. It permits only a namespaced direct child of an external
volume, mounts the source read-only, disables networking, forbids desktop state
and requires an exact source-volume confirmation in build mode. It then checks
the completed image using read-only loop devices and the configured-root
policy inspector. The separate `scripts/plan-sd-write-macos.sh` accepts that
image only for read-only physical-media identity validation; neither script
implements an SD write.
