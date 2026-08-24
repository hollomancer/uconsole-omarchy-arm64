# Minimal Hyprland validation layer

This directory is the Phase 2 bring-up layer, not an Omarchy configuration.

- `packages.lock` records every direct package installed by the Phase 2 script.
- `minimal.lua` is a deliberately plain Hyprland 0.56 Lua configuration.
- DSI-1 and DSI-2 receive transform 3; the fallback rule leaves HDMI and other
  outputs at their preferred orientation.
- UWSM is installed for the later Omarchy handoff but is not enabled.
- No display manager or autologin is configured.

The installer refuses to overwrite a different existing `hyprland.lua`. Once
this layer passes on hardware, Omarchy configuration must be installed as a
separate, reviewable transaction.
