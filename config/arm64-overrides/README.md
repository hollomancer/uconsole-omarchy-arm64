# ARM64 override boundary

This directory will contain the complete, small compatibility layer between
Arch Linux ARM and Omarchy. It must not contain kernel, device-tree, bootloader,
firmware, display timing or board-power fixes.

Every future override must identify:

- upstream package and consumer;
- ARM status and evidence;
- selected replacement or omission;
- functional difference;
- source/version/checksum;
- test and last verification date.

No active overrides exist during the research phase.
