
-- >>> uconsole-omarchy-arm64 session handoff (managed block; do not edit) >>>
-- Mode: autostart. The Omarchy shell starts with the session, and the same
-- on-demand bind remains available for restarting it after a deliberate stop.
--
-- Only select this after the manual stage has proven the shell on hardware. A
-- shell that wedges at startup is far harder to recover from than one launched
-- by hand.
--
-- Both entry points target the project's guard rather than
-- omarchy-launch-shell directly, and that indirection is load-bearing here:
-- Hyprland 0.56's Lua configuration has no exec-once, so hl.exec_cmd runs again
-- on every `hyprctl reload`. Upstream's launcher has no singleton guard, so an
-- unguarded autostart would leave one supervisor and one Quickshell per reload.
hl.bind("SUPER + O", hl.dsp.exec_cmd("omarchy-session-arm64"))
hl.exec_cmd("omarchy-session-arm64")
-- <<< uconsole-omarchy-arm64 session handoff <<<
