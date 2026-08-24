# ARM64 override boundary

This directory contains the small compatibility boundary between Arch Linux
ARM and Omarchy. It must not contain kernel, device-tree, bootloader, firmware,
display timing or board-power fixes.

Every future override must identify:

- upstream package and consumer;
- ARM status and evidence;
- selected replacement or omission;
- functional difference;
- source/version/checksum;
- test and last verification date.

Current files:

- `packages.toml` records reviewed replacements, omissions and deferred groups;
- `omarchy-source.lock` pins the upstream Quattro audit archive;
- `omarchy-staged-paths.lock` is the exact inert-source staging allowlist;
- `ACTIVATION-BLOCKED.md` records the gates before any staged code can run;
- `omarchy-core.packages` remains the validator's target core inventory.

These are active audit controls, not proof of a runnable Omarchy session. An
entry with `deferred`, `omit-initially`, `split-required` or
`thin-arm-package-required` must remain unavailable until its own gate closes.
