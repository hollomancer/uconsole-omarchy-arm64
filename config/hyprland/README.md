# Minimal Hyprland validation layer

This directory is the Phase 2 bring-up layer, not an Omarchy configuration.

- `packages.lock` records the 21 requested direct packages.
- `transaction.lock` records the 204-package incremental closure resolved
  against the exact configured Phase 1 root. Every payload and detached
  signature has a SHA-256.
- `minimal.lua` is a deliberately plain Hyprland 0.56 Lua configuration.
- DSI-1 and DSI-2 receive transform 3; the fallback rule leaves HDMI and other
  outputs at their preferred orientation.
- UWSM is installed for the later Omarchy handoff but is not enabled.
- No display manager or autologin is configured.

The installer refuses to overwrite a different existing `hyprland.lua`. Once
this layer passes on hardware, Omarchy configuration must be installed as a
separate, reviewable transaction.

The exact Phase 1 base package/configuration states are prerequisites. The
`--user` value must equal `admin_user` in `base-system-selection`; a stale
reference to Arch Linux ARM's source `alarm` account cannot redirect the
desktop into a locked or unowned home.

`research/resolve-hyprland-closure.sh` recreates the cache from the frozen
official `core`/`extra` databases, verifies package signatures with Pacman and
publishes files only when the generated lock exactly matches the committed
transaction. `install-hyprland.sh` accepts that cache through `--package-dir`
and never resolves a mirror.
