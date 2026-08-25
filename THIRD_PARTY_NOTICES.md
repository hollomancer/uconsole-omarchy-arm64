# Third-party notices

The repository's [`LICENSE`](LICENSE) applies to original project-authored
code, configuration, tests and documentation unless a file says otherwise. It
does not replace the licenses of upstream source, packages, fonts, themes,
firmware or other artifacts referenced, downloaded, built or installed by this
project.

This notice summarizes the important boundaries. The license files shipped by
each upstream project and built package remain authoritative.

## Packaged or staged upstream material

| Component | Project use | Upstream terms |
|---|---|---|
| [Omarchy](https://github.com/basecamp/omarchy), pinned at `d99d4fc6de0bc99d48c9935724fa19d7fb41ae54` | Selected userland is staged and packaged by `omarchy-arm64-userland` | MIT; its upstream `LICENSE` is installed with the package |
| `omacut`, `omacalc` and `ttfx` from [omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs), pinned at `40ddd6be195a704c1e4187fc7ecd3f2c8091e37b` | Locally built Omarchy core packages | MIT, with OFL-1.1 material additionally present in `omacalc`; package recipes install the upstream notices |
| [Yaru](https://github.com/ubuntu/yaru) icon material | Locally built icon package | GPL-3.0-only and CC-BY-SA-4.0; both upstream license files are installed |
| iA Writer fonts | Locally built font package | SIL Open Font License; upstream family license files are installed |
| `xdg-terminal-exec` | Locally built compatibility package | GPL-3.0-or-later; the package recipe retains that declaration |

The package recipes themselves are original project material under the root
MIT license. That license does not apply to the upstream payload produced or
installed by those recipes.

## Restricted uConsole CM5 evaluation input

The local `uconsole-cm5-dkms` evaluation recipe fetches
[`yota9/uconsole-cm5`](https://github.com/yota9/uconsole-cm5) at
`bf7a0ab55654c96b74d013520e1196d39f66391a`. Individual Linux driver files in
that archive carry GPL notices or SPDX identifiers. At the last audit, no
top-level license covered the upstream overlays, installer, audio policy and
project glue.

The root MIT license does **not** grant rights to that upstream material. Do
not redistribute the resulting source or binary package until its copyright
holder clarifies those terms. See
[`packaging/uconsole-cm5-dkms/PACKAGING-NOTICE`](packaging/uconsole-cm5-dkms/PACKAGING-NOTICE).

## Distribution packages and firmware

Arch Linux ARM packages, the Raspberry Pi kernel/firmware, Mesa, Hyprland and
their dependency closures retain their own package and upstream licenses. This
repository records, verifies and installs content-pinned artifacts; it does not
relicense them. Consult each installed package's license metadata before
redistributing a complete image.
