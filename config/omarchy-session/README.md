# Session handoff layer

This directory is the only place the compositor is allowed to learn about
Omarchy. It is applied by `scripts/activate-omarchy-session.sh`.

- `omarchy-session-arm64` is the project-owned launch guard, installed to
  `/usr/local/bin/omarchy-session-arm64`.
- `handoff-manual.lua` adds an on-demand bind only.
- `handoff-autostart.lua` adds the same bind plus a startup launch.

## Why a guard instead of a direct autostart

Hyprland 0.56.1's Lua configuration has no exec-once. Reading the source at
`v0.56.1`, the top-level API exposes `exec_cmd` and `exec_raw`, and
`hl.exec_cmd` calls the executor's `spawn()` directly rather than
`addExecOnce()`. `addExecOnce` is reachable only from the legacy `exec-once`
handler and from `hl.env`'s dbus propagation, and no first-launch predicate is
exposed to Lua at all. A Lua `hl.exec_cmd` therefore runs on every
configuration evaluation, including each `hyprctl reload`.

Upstream `omarchy-launch-shell` is a supervising relaunch loop with no
singleton guard: it restarts Quickshell up to five times a minute and exits
only when told to. Combining the two would leave one supervisor and one
Quickshell per reload, competing over the same panel and IPC socket.

The guard takes a non-blocking `flock` on a per-session lock in
`XDG_RUNTIME_DIR` and exits 0 when the lock is already held. The lock file
descriptor is inherited across `exec`, so it stays held for the supervisor's
lifetime. A duplicate launch becomes a no-op rather than a second shell.

## Why manual is the default

The manual stage keeps boot landing in the minimal compositor. A shell that
wedges, crashes or renders nothing cannot prevent a usable session, and the
recovery is to simply not press the key. Autostart makes a broken shell a
boot-time problem instead.

Select `--mode autostart` only after the manual stage has been validated on
hardware. `--deactivate` restores the byte-exact minimal configuration and
removes the guard in one step.

## What this layer never does

No display manager, autologin, UWSM, systemd unit, upstream Hyprland autostart,
migration execution or update path. The activated configuration is exactly the
reviewed `config/hyprland/minimal.lua` followed by one managed block, so both
activation and deactivation are byte-verifiable rather than parsed, and any
other `hyprland.lua` is treated as user configuration and refused.
