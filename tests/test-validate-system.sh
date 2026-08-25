#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=""
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

VALIDATOR="$REPO_ROOT/scripts/validate-system.sh"
PACKAGES="$REPO_ROOT/config/arm64-overrides/omarchy-core.packages"
PASS_FIXTURE="$TEST_DIR/fixtures/validate-pass"
FAIL_FIXTURE="$TEST_DIR/fixtures/validate-fail"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-validator-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-validator-test.*|/private/tmp/uconsole-validator-test.*|/var/folders/*/T/uconsole-validator-test.*|/private/var/folders/*/T/uconsole-validator-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

PASS_OUTPUT=""
if ! PASS_OUTPUT=$("$VALIDATOR" --phase omarchy --fixture "$PASS_FIXTURE" --packages-file "$PACKAGES"); then
  printf '%s\n' "$PASS_OUTPUT" >&2
  printf 'Expected complete fixture to pass\n' >&2
  exit 1
fi
if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq '[PASS] architecture'; then
  printf 'PASS fixture did not report architecture PASS\n' >&2
  exit 1
fi
if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq 'FAIL=0'; then
  printf 'PASS fixture reported a failure\n' >&2
  exit 1
fi
for required_pass in hardware-selection device-tree-uconsole local-console ssh-recovery uconsole-modules drm-nodes gpu-acceleration-gate internal-display backlight audio-alsa wifi-driver bluetooth-identity battery external-power suspend-capability input-devices power-key wayland-input hyprland-portal; do
  if ! printf '%s\n' "$PASS_OUTPUT" | grep -Fq "[PASS] $required_pass"; then
    printf 'PASS fixture did not report %s PASS\n' "$required_pass" >&2
    exit 1
  fi
done

DRM_FIXTURE="$TEST_TMP/dynamic-drm"
cp -R "$PASS_FIXTURE" "$DRM_FIXTURE"
mv "$DRM_FIXTURE/root/dev/dri/card0" "$DRM_FIXTURE/root/dev/dri/card1"
mv "$DRM_FIXTURE/root/dev/dri/renderD128" "$DRM_FIXTURE/root/dev/dri/renderD129"
DRM_OUTPUT=''
if ! DRM_OUTPUT=$("$VALIDATOR" --phase hardware --fixture "$DRM_FIXTURE" --packages-file "$PACKAGES"); then
  printf '%s\nExpected dynamically numbered DRM fixture to pass\n' "$DRM_OUTPUT" >&2
  exit 1
fi
printf '%s\n' "$DRM_OUTPUT" | grep -Fq '[PASS] drm-nodes' || { printf 'Dynamic DRM fixture did not pass node discovery\n' >&2; exit 1; }
printf '%s\n' "$DRM_OUTPUT" | grep -Fq 'card1 and renderD129' || { printf 'Dynamic DRM fixture reported the wrong nodes\n' >&2; exit 1; }

HEADLESS_GPU_FIXTURE="$TEST_TMP/headless-gpu"
cp -R "$PASS_FIXTURE" "$HEADLESS_GPU_FIXTURE"
rm "$HEADLESS_GPU_FIXTURE/commands/glxinfo.stdout"
HEADLESS_GPU_OUTPUT=''
if ! HEADLESS_GPU_OUTPUT=$("$VALIDATOR" --phase hardware --fixture "$HEADLESS_GPU_FIXTURE" --packages-file "$PACKAGES"); then
  printf '%s\nExpected V3DV-only hardware fixture to pass\n' "$HEADLESS_GPU_OUTPUT" >&2
  exit 1
fi
printf '%s\n' "$HEADLESS_GPU_OUTPUT" | grep -Fq '[WARN] opengl-acceleration' || { printf 'Headless GPU fixture did not report unavailable GLX as WARN\n' >&2; exit 1; }
printf '%s\n' "$HEADLESS_GPU_OUTPUT" | grep -Fq '[PASS] gpu-acceleration-gate' || { printf 'Headless GPU fixture did not accept V3DV evidence\n' >&2; exit 1; }

NO_GPU_FIXTURE="$TEST_TMP/no-userspace-gpu"
cp -R "$PASS_FIXTURE" "$NO_GPU_FIXTURE"
rm "$NO_GPU_FIXTURE/commands/glxinfo.stdout" "$NO_GPU_FIXTURE/commands/vulkaninfo.stdout"
NO_GPU_OUTPUT=''
NO_GPU_STATUS=0
NO_GPU_OUTPUT=$("$VALIDATOR" --phase hardware --fixture "$NO_GPU_FIXTURE" --packages-file "$PACKAGES" 2>&1)
NO_GPU_STATUS=$?
[[ $NO_GPU_STATUS -eq 1 ]] || { printf '%s\nExpected hardware fixture without userspace acceleration evidence to fail\n' "$NO_GPU_OUTPUT" >&2; exit 1; }
printf '%s\n' "$NO_GPU_OUTPUT" | grep -Fq '[FAIL] gpu-acceleration-gate' || { printf 'No-GPU fixture did not fail the Phase 1 acceleration gate\n' >&2; exit 1; }

GENERIC_FIXTURE="$TEST_TMP/generic-devices"
cp -R "$PASS_FIXTURE" "$GENERIC_FIXTURE"
printf 'raspberrypi,5-compute-module\n' > "$GENERIC_FIXTURE/root/proc/device-tree/compatible"
printf 'generic,dsi-panel\n' > "$GENERIC_FIXTURE/root/proc/device-tree/panel/compatible"
mv "$GENERIC_FIXTURE/root/sys/class/drm/card0-DSI-1" "$GENERIC_FIXTURE/root/sys/class/drm/card0-HDMI-A-1"
mv "$GENERIC_FIXTURE/root/sys/class/backlight/ocp8178" "$GENERIC_FIXTURE/root/sys/class/backlight/pwm-backlight"
mv "$GENERIC_FIXTURE/root/sys/class/power_supply/axp20x-battery" "$GENERIC_FIXTURE/root/sys/class/power_supply/generic-battery"
mv "$GENERIC_FIXTURE/root/sys/class/power_supply/axp20x-ac" "$GENERIC_FIXTURE/root/sys/class/power_supply/generic-ac"
printf 'card 0: vc4hdmi [vc4-hdmi], device 0: MAI PCM\n' > "$GENERIC_FIXTURE/commands/aplay.stdout"
printf 'Audio\n Sinks:\n  Generic HDMI Audio\n' > "$GENERIC_FIXTURE/commands/wpctl.stdout"
printf '/sys/bus/pci/drivers/ath10k_pci\n' > "$GENERIC_FIXTURE/commands/wifi_driver.stdout"
printf 'Controller 00:11:22:33:44:55 Generic [default]\n\tManufacturer: 0x0002 (2)\n\tPowered: yes\n' > "$GENERIC_FIXTURE/commands/bluetoothctl.stdout"
printf 'N: Name="Generic USB Keyboard"\nH: Handlers=kbd event0\n\nN: Name="Generic USB Mouse"\nH: Handlers=mouse0 event1\n' > "$GENERIC_FIXTURE/root/proc/bus/input/devices"
printf 'Mice:\n\tGeneric USB Mouse\n\nKeyboards:\n\tGeneric USB Keyboard\n' > "$GENERIC_FIXTURE/commands/hypr_devices.stdout"
GENERIC_OUTPUT=''
GENERIC_STATUS=0
GENERIC_OUTPUT=$("$VALIDATOR" --phase omarchy --fixture "$GENERIC_FIXTURE" --packages-file "$PACKAGES" 2>&1)
GENERIC_STATUS=$?
[[ $GENERIC_STATUS -eq 1 ]] || { printf '%s\nExpected generic-device impostor fixture to fail\n' "$GENERIC_OUTPUT" >&2; exit 1; }
for identity_fail in device-tree-uconsole internal-display backlight audio-alsa audio-pipewire wifi-driver bluetooth-identity battery external-power input-devices wayland-input; do
  if ! printf '%s\n' "$GENERIC_OUTPUT" | grep -Fq "[FAIL] $identity_fail"; then
    printf '%s\nGeneric-device fixture did not report %s FAIL\n' "$GENERIC_OUTPUT" "$identity_fail" >&2
    exit 1
  fi
done

FAIL_OUTPUT=""
FAIL_STATUS=0
FAIL_OUTPUT=$("$VALIDATOR" --phase hardware --fixture "$FAIL_FIXTURE" --packages-file "$PACKAGES" 2>&1)
FAIL_STATUS=$?
if [[ $FAIL_STATUS -ne 1 ]]; then
  printf '%s\n' "$FAIL_OUTPUT" >&2
  printf 'Expected failing fixture to exit 1; got %d\n' "$FAIL_STATUS" >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] architecture'; then
  printf 'Failing fixture did not report architecture FAIL\n' >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] opengl-acceleration'; then
  printf 'Failing fixture did not reject llvmpipe\n' >&2
  exit 1
fi
if ! printf '%s\n' "$FAIL_OUTPUT" | grep -Fq '[FAIL] vulkan-acceleration'; then
  printf 'Failing fixture did not reject software Vulkan\n' >&2
  exit 1
fi

STRICT_FIXTURE="$TEST_TMP/strict-fail"
cp -R "$PASS_FIXTURE" "$STRICT_FIXTURE"
rm "$STRICT_FIXTURE/commands/glxinfo.stdout" "$STRICT_FIXTURE/commands/hypr_devices.stdout"
printf 'Monitor DSI-1: 720x1280 transform: 0\n' > "$STRICT_FIXTURE/commands/hypr_monitors.stdout"
printf 'inactive\n' > "$STRICT_FIXTURE/commands/portal_status.stdout"
STRICT_OUTPUT=""
STRICT_STATUS=0
STRICT_OUTPUT=$("$VALIDATOR" --phase hyprland --fixture "$STRICT_FIXTURE" --packages-file "$PACKAGES" 2>&1)
STRICT_STATUS=$?
[[ $STRICT_STATUS -eq 1 ]] || { printf '%s\nExpected strict Hyprland fixture to fail\n' "$STRICT_OUTPUT" >&2; exit 1; }
for required_fail in opengl-acceleration display-orientation wayland-input hyprland-portal; do
  if ! printf '%s\n' "$STRICT_OUTPUT" | grep -Fq "[FAIL] $required_fail"; then
    printf '%s\nStrict fixture did not report %s FAIL\n' "$STRICT_OUTPUT" "$required_fail" >&2
    exit 1
  fi
done

printf 'validate-system fixtures: PASS\n'
