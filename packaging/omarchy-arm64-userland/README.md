# Omarchy ARM64 userland package

This recipe builds a deliberately thin, architecture-independent package from
the pinned Omarchy source archive. It contains the Quickshell UI, themes, the
reduced ARM menu and only the commands selected by
`omarchy-command-policy.tsv`.

The package does not contain or configure Hyprland, UWSM, a display manager,
Pacman repositories, migrations, kernel files, firmware, initramfs, a
bootloader or `/boot`. Installing it does not seed a home directory or start a
session.

Only three wrappers enter `/usr/bin`: `omarchy-launch-shell`, `omarchy-shell`
and `omarchy-menu`. The remaining selected helpers live beneath
`/usr/share/omarchy-arm64/bin` and enter `PATH` only in the launched shell
process tree. Eight names have small documented fail-closed implementations:
speaker tuning, DNS mutation, presentation-terminal actions, launcher removal,
and dynamic theme/wallpaper changes. The immutable first-run theme and
background are initialized by the separate conflict-safe user preparation.
