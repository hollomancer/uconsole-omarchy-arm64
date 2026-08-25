
-- >>> uconsole-omarchy-arm64 session handoff (managed block; do not edit) >>>
-- Mode: manual. The Omarchy shell is launched on demand and never at startup.
--
-- This is the first activation stage deliberately: a wedged or crashing shell
-- must not be able to prevent a usable session. Booting still lands in the
-- minimal compositor, and the shell is opted into per session.
--
-- The bind targets the project's guard rather than omarchy-launch-shell
-- directly. Upstream's launcher is a supervising relaunch loop with no
-- singleton guard, so a repeated keypress would start a second Quickshell.
hl.bind("SUPER + O", hl.dsp.exec_cmd("omarchy-session-arm64"))
-- <<< uconsole-omarchy-arm64 session handoff <<<
