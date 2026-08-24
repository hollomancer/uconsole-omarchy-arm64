# Omarchy Quattro ARM adaptation audit

The closest current implementation is
[`alexisraitano-myffu/omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm),
audited at ARM branch commit
`579f15c699dab01e2b3b12e2c4d2503873359be9` against its fetched Omarchy
Quattro base.

## Scope and divergence

The branch is 33 commits ahead and 21 commits behind the observed current
upstream. Its three-dot diff changes 54 files, adding about 4,000 lines and
removing 52. Most added lines are installer code, ARM manifests, documentation
and seven shell test files. This is useful prior art, but too large and too
diverged to adopt wholesale.

Our compatibility layer should reuse concepts and small reviewed changes while
tracking Omarchy userland at one explicit upstream commit.

## Reusable design elements

| Element | Keep | Reason/constraint |
|---|---|---|
| Declarative replace/exclude/AUR/unavailable manifests | Yes | Makes every package decision reviewable and testable |
| ALARM pacman-server preservation | Yes | Omarchy's x86 mirrors cannot resolve aarch64 packages |
| Pi platform detection from device tree | Yes | Avoids PCI-only assumptions and confines Pi tuning |
| ARM-safe Limine no-op/guard | Yes, narrowly | Pi firmware boot must remain owned below Omarchy |
| Explicit home seeding for an existing user | Yes | `/etc/skel` does not apply after account creation |
| Migration-marker and command-mode tests | Yes | Prevents silent replay and missing-command failures |
| Conservative Pi Hyprland profile | Test first | Animation/rounding reductions are policy, not hardware fixes |
| Monolithic replacement installer | No | Too much rebase surface and mixes system/user/package concerns |
| Automatic AUR compilation on target | No by default | Slow, high-write and capable of filling an SD card |
| Hardware installer leaves | No | uConsole hardware remains entirely outside Omarchy |

## Measured package lessons

The community fork reconciles the 148 base entries as 123 repository-resolved
packages after two name substitutions, 11 AUR builds, 13 unavailable packages
and one source-bootstrapped AUR helper. Our earlier exact-name query found 121
matches; the apparent discrepancy is exactly the two substitutions:

```text
nvim -> neovim
ttf-jetbrains-mono-nerd-basic -> ttf-jetbrains-mono-nerd
```

Three AUR-only entries were found to be load-bearing rather than merely
optional: `xdg-terminal-exec`, `mise-bin` and `ufw-docker`. We will not assume
all three are core for this target:

- `xdg-terminal-exec` is core because Omarchy's terminal dispatch depends on
  it;
- `mise-bin` is required only for the development-tool group;
- `ufw-docker` is required only if the Docker integration group is selected.

Two repository packages absent from the upstream base list are operationally
important: `zram-generator` activates Omarchy's shipped zram policy and
`pipewire-pulse` supplies the PulseAudio compatibility API used by Omarchy
audio commands and applications.

The fork lists seven first-party packages without an ARM build:
`omacalc`, `omacut`, `omawrite`, `omarchy-nvim`, `ttfx`, `tobi-try` and
`hyprland-preview-share-picker`. Missing first-party packages must be separated
into core-visible, optional and safely degradable behavior before any source
build is scheduled.

## Failure cases to turn into acceptance tests

The first real ARM installation exposed failures that clean VM/package tests
missed. These become project requirements:

| Failure observed in prior art | Required protection here |
|---|---|
| ALARM keyring unavailable/trust not initialized | verify keyring before the first package transaction |
| AUR build filled a 15 GB disk | preflight free space; optional AUR phase off by default; build packages off-target where practical |
| `omarchy` package absent meant a healthy bare compositor | assert expected commands, Quickshell process, menu and binding count, not merely Hyprland exit status |
| existing user never received `/etc/skel` | seed from a versioned manifest with per-file conflict policy |
| re-run overwrote user configuration | install only missing/unchanged defaults; atomic staging and explicit backups |
| live config reload raced a deploy | stage then atomically switch; suppress/reload deliberately |
| migration markers omitted `.sh` | compare exact migration filenames and fail closed |
| one unavailable package blocked all later migrations | classify migration package actions and record a deliberate ARM disposition |
| Limine refresh remained reachable | test every reset/update entrypoint against forbidden boot-path writes |
| absent `ttfx` caused a respawn loop | disabled features must fail once, visibly and without retry loops |
| `pipewire-pulse` and `zram-generator` were only implied | validate service/runtime behavior, not just config-file presence |
| two commands relied on package install mode, not Git mode | verify installed executable modes from the package payload |
| keyboard layout was never asked on an existing system | require an explicit layout before enabling the graphical login |

## Update implications

`omarchy update` is untested on ARM in the community port. Our update adapter
must therefore start as a dry-run/audit wrapper, not an alias for the upstream
command. Before enabling an update it must:

1. fetch and pin the prospective Omarchy source revision;
2. diff package lists, migrations and all paths capable of touching `/boot`,
   pacman servers, mkinitcpio, Limine or Snapper;
3. regenerate the package classification and reject unknown entries;
4. run the ARM tests and build missing first-party packages in a clean builder;
5. hash the hardware boot manifest before and after a disposable-image update;
6. promote only the userland/config package set that passed.

This keeps normal upstream migrations available without giving Omarchy control
of the uConsole kernel or Pi firmware chain.

## Quickshell and command activation audit

The pinned Quattro source contains 432 regular files in `bin/`. A token scan of
`shell/`, `default/hypr/` and `config/hypr/` finds 141 distinct
`omarchy-*` identifiers. Of those, 118 match shipped commands; the other 23 are
plugin/notification IDs or partial example strings. This is too broad to expose
wholesale during first activation.

More importantly, `shell/services/PluginRegistry.qml` treats first-party
non-bar plugins as implicitly enabled. An empty `plugins` array does not produce
a minimal shell. Unless named in `disabledPlugins`, background, clipboard,
dev-gallery, emoji, image-picker, lock, menu, notifications, OSD, polkit,
reminders, battery, idle, media and nightlight components remain loadable or
active. Bar widgets become active when placed in the layout.

The upstream Hyprland default also starts more than the shell. Its startup
handler imports the user environment and then invokes shell launch, first-run
provisioning, power-profile initialization, monitor watching, udiskie and
post-boot hooks. Several of those cross the ARM system/hardware ownership
boundary or depend on packages not yet classified.

Therefore the first runnable ARM userland must use three explicit controls:

1. an ARM Hyprland entry point that does not import upstream autostart until
   each command has an approved disposition;
2. a minimal `shell.json` with an explicit `disabledPlugins` list, not merely
   an empty `plugins` list;
3. a generated command allowlist that installs/exposes only commands consumed
   by enabled components and fails when a new upstream command reference is
   unclassified.

Those controls are now implemented and tested against the pinned archive:

- the sorted 37-manifest inventory is locked at SHA-256
  `47c2c3d67e4dea367147124badd47e603a9b6a35004b1b4a91b751f9bba9bc56`;
- 16 plugins are enabled and 21 are named in `disabledPlugins`;
- the sorted 432-command inventory is locked at SHA-256
  `ade2db01589567a730cd1b7018712a6bf11c43f45e8e3889143305a908c0d777`;
- only `omarchy-launch-shell`, `omarchy-shell` and `omarchy-menu` may enter
  `/usr/bin`; 34 reviewed commands remain internal-only to `OMARCHY_PATH`;
- the 37 packaged command implementations have a closed transitive graph: 25
  shipped-command references are selected, no implementation sources an
  unbundled library, and no selected implementation reaches a blocked command;
- the reduced menu has no package, update, migration, boot, kernel or firmware
  action; and
- any new manifest, command or reference changes an inventory digest and fails
  `research/audit-omarchy-activation.sh`.

The resulting `omarchy-arm64-userland` package is architecture-independent and
contains no Hyprland defaults, `/etc`, service, home, migration or boot payload.
Two network-disabled aarch64 builds were byte-identical at SHA-256
`4824a5b829cf6633e0d329307341398353fe14881c9642730e96bb7c31d93b71`.
Pacman install/removal passed in a disposable ARM64 root.

Eight selected names intentionally use small ARM first-run implementations
instead of their broad upstream scripts. Speaker tuning reports unavailable;
DNS is query-only and remains owned by Phase 1; presentation-terminal and
launcher-removal actions are rejected; and the four dynamic theme/wallpaper
mutation entry points are rejected. The initial Tokyo Night colors/background
are seeded directly from immutable package content, so the visual experience
does not require the broad theme mutation graph. These are visible functional
reductions, not silent substitutions.

An earlier `pkgrel=1` candidate was rejected after the recursive audit found
that top-level helpers alone were not a closed runtime graph. It was never
promoted; `pkgrel=2` added the required safe transitive implementations and
`pkgrel=3` adds the exact Foot configuration, rendered Tokyo Night theme,
Omarchy icon font, fontconfig policy and explicit runtime dependencies. The
audit now fails on any unselected call or sourced shell library.

`scripts/prepare-omarchy-user.sh` separately enforces the user boundary. It
refuses existing Omarchy/Foot config or state, seeds only the reviewed
`shell.json`, pinned `foot.ini` and immutable initial visual state, and creates
the 87 historical migration names as empty completion markers without
running them. An exact rerun is idempotent; any changed file is a hard failure.
It does not modify Hyprland or start a session.

The inert source stage remains outside `PATH`; it is never the runtime tree.
The actual Quickshell launch still waits for live CM5 hardware and minimal
Hyprland validation.
