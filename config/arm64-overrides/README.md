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
- `omarchy-base-package-policy.tsv` classifies every one of the 148 pinned
  Quattro base-package entries and contains no implicit fallback;
- `omarchy-update-commands.lock` assigns all 28 update-boundary commands to an
  allow, ARM replacement, hardware/package block or deferred disposition;
- `omarchy-migration-baseline.lock` content-locks all 87 historical migrations
  as baseline markers that a fresh install must not execute;
- `omarchy-source.lock` pins the upstream Quattro audit archive;
- `omarchy-staged-paths.lock` is the exact inert-source staging allowlist;
- `ACTIVATION-BLOCKED.md` records the gates before any staged code can run;
- `omarchy-core.packages` remains the validator's target core inventory.

These are active audit controls, not proof of a runnable Omarchy session. An
entry with `deferred`, `omit-initially`, `split-required` or
`thin-arm-package-required` must remain unavailable until its own gate closes.
The generated repository/version/architecture evidence lives in
`research/package-audit/omarchy-base-packages.tsv`; regenerate it with
`research/audit-omarchy-base-packages.sh` and the hashes in
`research/package-audit/inputs.yaml`.
