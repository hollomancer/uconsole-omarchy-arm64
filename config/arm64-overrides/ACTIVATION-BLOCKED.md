# Omarchy source is intentionally inactive

This tree is a content-pinned audit input. It is not an installed Omarchy
package and must not be added to `PATH` or used as `OMARCHY_PATH` yet.

Activation gate status at the pinned source revision:

1. **OPEN — live CM5:** uConsole hardware and accelerated graphics must pass.
2. **OPEN — live CM5:** minimal Hyprland must pass at native mode/transform.
3. **PASS — off-target:** the core package manifest has no unknown or silent
   substitutions; local package differences remain explicit.
4. **PASS — off-target:** all 37 plugin manifests, all 432 commands and all 141
   shell/Hyprland references are inventory-locked. Sixteen plugins are
   enabled, twenty-one are explicitly disabled, and every unlisted command is
   blocked by default.
5. **PASS — off-target:** the thin package exposes only three wrappers and has
   no updater, migration, package-manager, Limine, Snapper, firmware, kernel,
   initramfs, boot or Hyprland-configuration payload.
6. **PASS — off-target:** user preparation is exact/idempotent or fails on any
   existing `~/.config/omarchy` or migration-state conflict.
7. **PASS — off-target:** all 87 historical migrations are content-locked and
   initialized only as zero-byte `baseline-do-not-run` markers; none execute.
8. **OPEN — live CM5:** the exact userland package and enabled plugins must pass
   a manual Quickshell session without software rendering or hardware regressions.

The separate `omarchy-arm64-userland` candidate package is that reviewed
userland transaction, but installing or launching it on the development card
still waits for gates 1 and 2. Permission must never be inferred from this inert
staged source tree.
