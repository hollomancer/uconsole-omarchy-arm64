# Phase 6 — update mechanism design

Status: **design only.** Nothing here is implemented. `scripts/plan-omarchy-update.sh`
exists and is audit-only; the orchestrator described below does not exist yet.

The audited upstream flow and the 28 content-locked command dispositions are in
[`research/omarchy-update-audit-results.yaml`](../research/omarchy-update-audit-results.yaml)
and [`config/arm64-overrides/omarchy-update-commands.lock`](../config/arm64-overrides/omarchy-update-commands.lock).
This document decides what replaces the blocked parts.

## The problem in one paragraph

`omarchy-update` prunes the package cache, takes a Snapper snapshot, bootstraps
the Omarchy and Arch **x86** keyrings, overwrites `pacman.conf` and the
mirrorlist with Omarchy x86 sources, runs an unpinned rolling `pacman -Syu`,
executes every migration lacking a marker, updates AUR and mise packages, and
removes orphans. On this port, five of those steps can destroy the system: the
keyring bootstrap displaces the Arch Linux ARM trust root, the mirror rewrite
points at repositories with no aarch64 packages, the rolling transaction can
replace the kernel, orphan removal can take hardware dependencies with it, and
the firmware step writes an x64 EFI payload into `/boot`.

## Three ownership domains

The single most important decision is that "update" is not one operation. Three
domains change on different schedules, carry different risk, and must never be
updated by the same command.

| Domain | Contents | Owner | Update trigger |
|---|---|---|---|
| **Hardware** | kernel, DKMS modules, DTBs, overlays, `config.txt`, `cmdline.txt`, firmware | this project's hardware package | explicit, deliberate, never automatic |
| **Base** | Arch Linux ARM system packages | Arch Linux ARM | routine, but pinned per transaction |
| **Desktop** | Omarchy userland, shell closure, themes, fonts | this project's promoted ARM userland package | follows promoted upstream commits |

Upstream conflates all three. Keeping them separate is what makes the boot
chain safe: a desktop update that cannot address the hardware domain cannot
brick the device, whatever else it gets wrong.

Enforcement is not by convention. The updater refuses to proceed if a
transaction's file list intersects the hardware domain's paths, and it compares
the boot manifest before and after every run (see **Boot manifest gate**).

## Promotion, not rolling

Upstream resolves packages on the target at update time. This port resolves
them off-target, ahead of time, and ships the result as an exact transaction —
the same pattern already proven by `config/hyprland/transaction.lock` (204
packages) and `config/omarchy-shell/transaction.lock` (24 packages).

An update is therefore a **promotion pipeline**, not a command the device runs
against a mirror:

```
pinned upstream commit
    ↓  plan-omarchy-update.sh          (exists; audit-only, runs no candidate code)
candidate classified, no unknowns
    ↓  resolve-update-transaction.sh   (future; exact closure from frozen DBs)
content-locked transaction + signatures
    ↓  build + test on a disposable image  (future)
evidence recorded
    ↓  sign                             (future; blocked on a signing policy)
promoted transaction
    ↓  apply-omarchy-update.sh          (future; offline, boot-manifest gated)
updated development root
```

The device never resolves a dependency graph, never contacts an Omarchy mirror,
and never builds from AUR. It applies a transaction that was already resolved,
tested and signed elsewhere.

This is the largest deliberate divergence from upstream, and it is what makes
`pacman -Syu`'s failure modes structurally unreachable rather than merely
discouraged.

## Command dispositions

The 28 locked commands already carry dispositions. They map onto the design as
follows.

**Reused unchanged (9 `allow-userland`).** Free-space preflight, update lock,
status, elapsed time, transcript analysis, user notification, stay-awake,
confirmation, cache pruning. None owns packages or hardware. Reusing them keeps
the user-visible update experience recognisably Omarchy.

**Replaced (5 `replace-arm`).** These are the orchestrator's actual scope:

| Upstream | ARM replacement |
|---|---|
| `omarchy-update` | `omarchy-update-arm64` — sequences only the allowed steps |
| `omarchy-update-system-pkgs` | applies the promoted exact transaction offline |
| `omarchy-update-pacman-guard` | redirects to the ARM orchestrator, never the x86 flow |
| `omarchy-update-available` | queries the promoted ARM source, not the x86 repository |
| `omarchy-migrate` | runs only post-baseline migrations with an explicit disposition |

**Blocked (12).** Seven package-domain and five hardware-domain commands stay
unavailable: channel switching, pacman refresh, keyring bootstrap, AUR, orphan
removal, dev-mode git updates, conflict retries; and Limine refresh, Snapper
snapshots, firmware updates, factory reset and its finish step.

**Deferred (2).** `mise` development runtimes and restart prompting sit outside
the core desktop transaction.

## Boot manifest gate

`build-image.sh` already writes `uconsole-build-manifest.json`, recording every
`/boot` file and a rollup digest. The updater reuses it as the hardware-domain
tripwire:

1. Record the boot manifest before the transaction.
2. Apply the transaction offline.
3. Recompute the boot manifest.
4. Any difference **fails the update** unless an approved hardware transition
   was explicitly requested for this run.

This is what the brief means by "do not create an update mechanism that
silently replaces uConsole kernel configuration." A desktop update that touches
`/boot` is by definition a bug, and this gate turns that from a review question
into a mechanical check.

## Migrations

87 historical migrations are content-locked as `baseline-do-not-run` and seeded
as empty markers, so a fresh install never replays x86-era upgrade scripts.

For future migrations the rule is: every new migration must be content-locked
and assigned an explicit ARM disposition before promotion. `plan-omarchy-update.sh`
already fails on any unclassified migration, so an upstream commit that adds one
cannot be promoted until a human classifies it. Allowed migrations run against
disposable user data and conflict fixtures before reaching a real root.

The static scan found 39 privileged or system-path references, 26 package
mutations and 10 boot-ownership references across the baseline set. That
distribution is the reason the default is deny.

## Rollback — the honest gap

Upstream's rollback is Snapper plus Btrfs plus Limine. This port has none of
those, and adding them would hand the boot chain back to the desktop layer.

Three options, in the order they should be adopted:

1. **Image-level (available now, unbuilt).** Keep the previous `.img` and its
   manifest; recover by re-flashing. Slow and manual, but it needs no new
   on-device machinery and works today for a development card.
2. **A/B root partitions (the design target).** Two ext4 roots; update the
   inactive one, switch by rewriting the root PARTUUID in `cmdline.txt`. Fits
   the Pi boot chain without Btrfs. The complication is that `cmdline.txt` and
   `config.txt` live in the single shared FAT partition, so the switch itself
   is the one hardware-domain write an update may legitimately make — and it
   must be the *only* one, gated and logged.
3. **Btrfs snapshots (rejected for now).** Closest to upstream, but it changes
   the filesystem model and pulls boot-chain assumptions back in.

Recommendation: ship image-level rollback for bring-up, and treat A/B as the
prerequisite for anything resembling unattended updates. Until one exists,
updates are a deliberate, attended operation on a card you are willing to
re-flash.

## Hard prerequisites

None of this can ship without these, and all three are currently open:

- **A signing policy and an offline key.** The five built core packages and the
  userland package are reproducible but unsigned. An update mechanism that
  applies unsigned local packages is a worse trust root than the x86 one it
  replaces. This is the single hardest blocker.
- **A signed ARM repository.** The Hyprland and shell caches are content-locked
  and resolver-verified but carry no project-signed distribution metadata.
- **Live hardware validation.** No transaction should be promoted on evidence
  from an emulated build alone.

## What to build first

In dependency order, once hardware passes:

1. Signing policy and offline key — everything else is gated on it.
2. `resolve-update-transaction.sh`, generalising the existing Hyprland and
   shell closure resolvers.
3. The boot manifest gate as a standalone, testable check.
4. `apply-omarchy-update.sh`, offline and plan-first like every other
   transaction here.
5. `omarchy-update-arm64`, sequencing the 9 reused commands around the above.

Steps 2 and 3 are independent of hardware and could begin now. Step 1 needs a
decision from the maintainer, not code.
