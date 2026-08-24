# Omarchy source is intentionally inactive

This tree is a content-pinned audit input. It is not an installed Omarchy
package and must not be added to `PATH` or used as `OMARCHY_PATH` yet.

Activation remains blocked until all of these conditions pass:

1. The uConsole hardware and accelerated-graphics gates pass on the CM5.
2. Minimal Hyprland passes at the panel's native mode and correct transform.
3. The core package manifest has no unknown or silently substituted entries.
4. The Quickshell/command dependency allowlist is complete.
5. ARM-safe wrappers prevent access to Limine, Snapper, Pacman-mirror,
   firmware, kernel, initramfs and boot-configuration update paths.
6. Existing user files have an explicit seed/conflict policy.
7. Historical migrations have an audited initial-state policy.

The next activation step must be a separate package or installer transaction.
It must never infer permission from the presence of this staged source tree.
