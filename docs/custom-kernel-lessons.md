# What the custom kernel teaches us

Observed on **2026-08-24** at
`OuinOuin74/linux-clockwork-arch` commit
`eef4936b13e581bc91054eaae20e18fa4d2b6120`. The selected Phase 1 baseline is
now Arch Linux ARM `linux-rpi-16k` plus the pinned `yota9/uconsole-cm5`
DKMS/overlay delta. The custom kernel is an oracle and recovery reference, not
the default.

## Main conclusion

The custom kernel does not reveal a missing general-purpose Pi kernel feature.
The selected stock 16K config already has 16K pages, Landlock, F2FS
compression, I2C-GPIO, power-supply core, MIPI DSI, VC4/V3D, backlight core and
the audio-card framework. Its missing uConsole-facing symbols correspond to the
nine modules that have already built against the exact stock headers.

That means the custom tree is most useful as a behavioral checklist. It tells
us which board-specific details have mattered on working systems and gives us
fallback implementations when one of the cleaner DKMS paths fails.

## Behaviors to carry or test

| Custom-kernel evidence | Lesson for stock 16K + DKMS | Initial treatment |
|---|---|---|
| CM5 boots with `dwc2,dr_mode=host` | The internal keyboard/trackball need a proven USB host path | Keep the official Arch setting and validate both devices |
| `usbhid.mousepoll=8` | Trackball responsiveness may depend on HID polling | Test stock first; add only after latency/power comparison |
| `brcmfmac roamoff=1 feature_disable=0x282000` | Community builds have needed a Wi-Fi stability workaround | Preserve as a diagnostic profile, not an unconditional default |
| `vc4-kms-v3d-pi5,cma-384` | CMA and Pi-5-specific KMS selection may affect DSI scanout | Start with Arch's `vc4-kms-v3d`; switch only with captured DRM/CMA evidence |
| Fixed DSI byte and DPI clocks | The panel timing is not discoverable from generic CM5 support alone | Already carried by the selected base overlay |
| Battery-capacity and nominal-voltage overrides | Fuel-gauge correctness depends on the actual installed cells | Verify the fixed 6.7 Ah/24.79 Wh profile, then parameterize if required |
| PMIC design-capacity programming | A visible battery percentage is not enough; the gauge needs to converge | Test charge/discharge cycles and PMIC register behavior |
| Separate headphone amplifier switch | Speaker mute on jack insertion is board-specific | Use the integrated DKMS audio path; keep this as the fallback design |
| Physical panel dimensions and checked DCS writes | The selected panel module has useful revision detection but weaker error handling | Identify the real panel revision, then upstream focused fixes |
| `dtparam=ant2` in both implementations | The antenna selection is corroborated independently | Carry it in the hardware-owned boot fragment |

## Contradictions are test cases

The custom overlay says “Do NOT load `dwc2` on Pi5,” while the same repository's
committed CM5 `config.txt` loads `dtoverlay=dwc2,dr_mode=host`. Arch's official
`linux-rpi-16k` configuration does too. We will retain the distribution setting
for the first image and let keyboard/trackball enumeration decide; no comment
from one source is strong enough to override two boot configurations.

The README also advertises command-line settings that are absent from its
committed `cmdline.txt`. This reinforces the rule that committed package
payload, exact source and live validation outrank prose.

## Improvements not to inherit automatically

- The custom overlay enables RP1 I2C1 and disables an Ethernet alias even
  though neither is part of the minimum demonstrated uConsole delta.
- Its package mutates `fstab`, `cmdline.txt` and `config.txt` from a package
  hook and uses MD5 source checks. Our hardware package will own files, while
  the image builder renders machine identity and partition UUIDs explicitly.
- Its AppArmor default differs from stock, but no selected Omarchy core
  component has yet established AppArmor as a requirement.
- Its custom battery patch is richer than the DKMS version, but changing PMIC
  behavior without real charge/discharge evidence would increase risk.

The machine-readable hypothesis list and exact hashes are in
[`../research/custom-kernel-delta.yaml`](../research/custom-kernel-delta.yaml).

