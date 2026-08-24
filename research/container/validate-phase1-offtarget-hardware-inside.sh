#!/usr/bin/env bash

# Static validation of the exact Phase 1 boot artifacts. This script runs in an
# AArch64 container with the target root and repository mounted read-only.

set -u
set -o pipefail

ROOT=/source/root
TMP="$ROOT/tmp/uconsole-offtarget"
RELEASE=6.18.45-1-rpi-16k
MODULE_ROOT="$ROOT/usr/lib/modules/$RELEASE"
BUILD_ROOT="$MODULE_ROOT/build"
DTC=/usr/lib/modules/$RELEASE/build/scripts/dtc/dtc
FDTOVERLAY=/usr/lib/modules/$RELEASE/build/scripts/dtc/fdtoverlay
BASE_DTB=/boot/bcm2712-rpi-cm5-cm5io.dtb
BASE_OVERLAY=/boot/overlays/uconsole-cm5-base.dtbo
AUDIO_OVERLAY=/boot/overlays/uconsole-audio-cm5.dtbo
FAILURES=0
WARNINGS=0

pass() {
  printf '[PASS] %-24s %s\n' "$1" "$2"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '[WARN] %-24s %s\n' "$1" "$2"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf '[FAIL] %-24s %s\n' "$1" "$2" >&2
}

state_field() {
  local file=$1
  local key=$2
  awk -F '=' -v wanted="$key" '$1 == wanted { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1 && value != "") print value; else exit 1 }' "$file"
}

require_file() {
  local label=$1
  local path=$2
  if [[ -s "$path" && ! -L "$path" ]]; then
    pass "$label" "${path#"$ROOT"}"
  else
    fail "$label" "missing, empty or unsafe: ${path#"$ROOT"}"
  fi
}

mkdir -p "$TMP"

if [[ $(uname -m) == aarch64 ]] && readelf -h "$ROOT/usr/bin/bash" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64'; then
  pass architecture 'AArch64 container and target userspace'
else
  fail architecture 'runner or target userspace is not AArch64'
fi

STATE="$ROOT/var/lib/uconsole-omarchy-arm64/hardware-selection"
if [[ -f "$STATE" && ! -L "$STATE" ]] &&
   [[ $(state_field "$STATE" kernel_release) == "$RELEASE" ]] &&
   [[ $(state_field "$STATE" kernel_package) == linux-rpi-16k ]]; then
  pass hardware-state "linux-rpi-16k $RELEASE"
else
  fail hardware-state 'exact selected kernel state is absent or differs'
fi

require_file cm5-dtb "$ROOT$BASE_DTB"
require_file base-overlay "$ROOT$BASE_OVERLAY"
require_file audio-overlay "$ROOT$AUDIO_OVERLAY"
require_file kernel-image "$ROOT/boot/kernel8.img"
require_file initramfs "$ROOT/boot/initramfs-linux.img"

OVERLAY_OK=0
if [[ -x "$ROOT$FDTOVERLAY" && -x "$ROOT$DTC" ]]; then
  if chroot "$ROOT" "$FDTOVERLAY" \
      -i "$BASE_DTB" \
      -o /tmp/uconsole-offtarget/merged.dtb \
      "$BASE_OVERLAY" "$AUDIO_OVERLAY" \
      >"$TMP/fdtoverlay.stdout" 2>"$TMP/fdtoverlay.stderr"; then
    OVERLAY_OK=1
    pass overlay-application 'both installed overlays apply to the exact CM5 DTB'
  else
    fail overlay-application 'fdtoverlay rejected the installed DTB/DTBO set'
  fi
else
  fail overlay-tools 'kernel-header dtc/fdtoverlay tools are absent'
fi

if [[ $OVERLAY_OK -eq 1 ]]; then
  BASE_DTC_OK=0
  MERGED_DTC_OK=0
  if chroot "$ROOT" "$DTC" -I dtb -O dts \
      -o /tmp/uconsole-offtarget/base.dts "$BASE_DTB" \
      >"$TMP/base.stdout" 2>"$TMP/base.warn"; then
    BASE_DTC_OK=1
  else
    fail base-dtb-decompile 'dtc could not decompile the exact base DTB'
  fi
  if chroot "$ROOT" "$DTC" -I dtb -O dts \
      -o /tmp/uconsole-offtarget/merged.dts /tmp/uconsole-offtarget/merged.dtb \
      >"$TMP/merged.stdout" 2>"$TMP/merged.warn"; then
    MERGED_DTC_OK=1
  else
    fail merged-dtb-decompile 'dtc could not decompile the temporary merged DTB'
  fi

  if [[ $BASE_DTC_OK -eq 1 && $MERGED_DTC_OK -eq 1 ]]; then
    MERGED_DTS="$TMP/merged.dts"
    REQUIRED_DTS_STRINGS=(
      'model = "Raspberry Pi Compute Module 5";'
      'compatible = "cw,cwu50";'
      'compatible = "ocp8178-backlight";'
      'compatible = "x-powers,axp228", "x-powers,axp223", "x-powers,axp221";'
      'compatible = "simple-audio-card";'
      'simple-audio-card,name = "RP1-Audio-Out";'
      'compatible = "simple-audio-amplifier";'
      'battery@0 {'
    )
    MISSING_DTS=0
    for required in "${REQUIRED_DTS_STRINGS[@]}"; do
      if ! grep -Fq "$required" "$MERGED_DTS"; then
        MISSING_DTS=$((MISSING_DTS + 1))
        printf '       missing DTS evidence: %s\n' "$required" >&2
      fi
    done
    if [[ $MISSING_DTS -eq 0 ]]; then
      pass merged-dtb-nodes 'panel, backlight, PMIC/battery and RP1 audio nodes present'
    else
      fail merged-dtb-nodes "$MISSING_DTS required node/properties absent"
    fi

    if grep -Fq '__fixups__ {' "$MERGED_DTS" || grep -Fq '<0xffffffff>' "$MERGED_DTS"; then
      fail overlay-fixups 'temporary merged tree retains unresolved fixups/phandles'
    else
      pass overlay-fixups 'no unresolved __fixups__ or 0xffffffff phandles'
    fi

    sed 's#/tmp/uconsole-offtarget/base.dts:#DT:#' "$TMP/base.warn" | sort -u >"$TMP/base.normal"
    sed 's#/tmp/uconsole-offtarget/merged.dts:#DT:#' "$TMP/merged.warn" | sort -u >"$TMP/merged.normal"
    comm -13 "$TMP/base.normal" "$TMP/merged.normal" >"$TMP/new.warn"
    BASE_WARNING_COUNT=$(wc -l <"$TMP/base.warn")
    MERGED_WARNING_COUNT=$(wc -l <"$TMP/merged.warn")
    NEW_WARNING_COUNT=$(wc -l <"$TMP/new.warn")
    if [[ $NEW_WARNING_COUNT -eq 0 ]]; then
      pass overlay-dtc-warnings "base=$BASE_WARNING_COUNT merged=$MERGED_WARNING_COUNT; no new warnings"
    else
      warn overlay-dtc-warnings "base=$BASE_WARNING_COUNT merged=$MERGED_WARNING_COUNT new=$NEW_WARNING_COUNT; known root unit-address warnings"
    fi
    pass merged-dtb-sha256 "$(sha256sum "$TMP/merged.dtb" | awk '{print $1}')"
  fi
fi

CONFIG="$BUILD_ROOT/.config"
if [[ -f "$CONFIG" ]]; then
  REQUIRED_CONFIG=(
    CONFIG_ARM64_16K_PAGES=y
    CONFIG_DEVTMPFS=y
    CONFIG_DEVTMPFS_MOUNT=y
    CONFIG_EXT4_FS=y
    CONFIG_MMC=y
    CONFIG_MMC_SDHCI=y
    CONFIG_MMC_SDHCI_OF_DWCMSHC=m
    CONFIG_USB=y
    CONFIG_USB_DWC2=y
    CONFIG_USB_DWC2_DUAL_ROLE=y
    CONFIG_HID=y
    CONFIG_HID_GENERIC=y
    CONFIG_USB_HID=y
    CONFIG_DRM_VC4=m
    CONFIG_DRM_V3D=m
    CONFIG_BRCMFMAC=m
    CONFIG_BT_HCIUART=m
  )
  MISSING_CONFIG=0
  for required in "${REQUIRED_CONFIG[@]}"; do
    if ! grep -Fqx "$required" "$CONFIG"; then
      MISSING_CONFIG=$((MISSING_CONFIG + 1))
      printf '       missing kernel config: %s\n' "$required" >&2
    fi
  done
  if [[ $MISSING_CONFIG -eq 0 ]]; then
    pass kernel-config '16 KiB ARM64, root storage, USB HID, V3D/VC4 and radios enabled'
  else
    fail kernel-config "$MISSING_CONFIG required selections differ"
  fi
else
  fail kernel-config 'installed headers do not expose the exact .config'
fi

SYSTEM_MAP="$BUILD_ROOT/System.map"
if depmod -e -F "$SYSTEM_MAP" -b "$ROOT" -n "$RELEASE" \
    >"$TMP/depmod.stdout" 2>"$TMP/depmod.stderr"; then
  if [[ -s "$TMP/depmod.stderr" ]]; then
    fail module-symbols 'depmod reported unresolved symbols'
  else
    pass module-symbols 'depmod reports no unresolved symbols'
  fi
else
  fail module-symbols 'depmod exact-release audit failed'
fi

CUSTOM_MODULES=(
  panel_cwu50
  ocp8178_bl
  axp20x
  axp20x_i2c
  axp20x_regulator
  axp20x_battery
  axp20x_adc
  snd_soc_simple_amplifier
  axp20x_pek
)
MODULE_METADATA_FAILURES=0
for module in "${CUSTOM_MODULES[@]}"; do
  VERMAGIC=''
  LICENSE=''
  if VERMAGIC=$(modinfo -b "$ROOT" -k "$RELEASE" -F vermagic "$module" 2>"$TMP/$module.modinfo.stderr") &&
     LICENSE=$(modinfo -b "$ROOT" -k "$RELEASE" -F license "$module" 2>"$TMP/$module.license.stderr") &&
     [[ "$VERMAGIC" == "$RELEASE "* ]] &&
     [[ "$LICENSE" == GPL* ]]; then
    :
  else
    MODULE_METADATA_FAILURES=$((MODULE_METADATA_FAILURES + 1))
    printf '       module metadata mismatch: %s\n' "$module" >&2
  fi
done
if [[ $MODULE_METADATA_FAILURES -eq 0 ]]; then
  pass dkms-metadata '9/9 uConsole modules have exact vermagic and GPL metadata'
else
  fail dkms-metadata "$MODULE_METADATA_FAILURES custom modules differ"
fi

MODULE_CLOSURES=(
  panel_cwu50
  ocp8178_bl
  axp20x_i2c
  axp20x_regulator
  axp20x_battery
  axp20x_adc
  snd_soc_simple_amplifier
  axp20x_pek
  sdhci_of_dwcmshc
  vc4
  v3d
  brcmfmac
  hci_uart
)
MODULE_CLOSURE_FAILURES=0
for module in "${MODULE_CLOSURES[@]}"; do
  if ! modprobe -d "$ROOT" -S "$RELEASE" -n -v "$module" \
      >"$TMP/$module.modprobe" 2>"$TMP/$module.modprobe.stderr"; then
    MODULE_CLOSURE_FAILURES=$((MODULE_CLOSURE_FAILURES + 1))
    printf '       dependency closure failed: %s\n' "$module" >&2
  fi
done
if [[ $MODULE_CLOSURE_FAILURES -eq 0 ]]; then
  pass module-closure 'uConsole, root storage, V3D/VC4, Wi-Fi and Bluetooth dry-resolve'
else
  fail module-closure "$MODULE_CLOSURE_FAILURES module closures failed"
fi

INITRAMFS_LIST="$TMP/initramfs.list"
if LC_ALL=C TERM=dumb chroot "$ROOT" lsinitcpio -l /boot/initramfs-linux.img \
    >"$INITRAMFS_LIST" 2>"$TMP/lsinitcpio.stderr"; then
  REQUIRED_INITRAMFS=(
    "usr/lib/modules/$RELEASE/kernel/drivers/gpu/drm/vc4/vc4.ko.xz"
    "usr/lib/modules/$RELEASE/kernel/drivers/gpu/drm/v3d/v3d.ko.xz"
    "usr/lib/modules/$RELEASE/kernel/drivers/mmc/host/sdhci-of-dwcmshc.ko.xz"
    usr/bin/fsck.ext4
    usr/bin/mount
    usr/bin/switch_root
    usr/bin/udevadm
    usr/lib/systemd/systemd
    usr/lib/systemd/systemd-udevd
  )
  MISSING_INITRAMFS=0
  for required in "${REQUIRED_INITRAMFS[@]}"; do
    if ! grep -Fxq "$required" "$INITRAMFS_LIST"; then
      MISSING_INITRAMFS=$((MISSING_INITRAMFS + 1))
      printf '       missing initramfs entry: %s\n' "$required" >&2
    fi
  done
  if [[ $MISSING_INITRAMFS -eq 0 ]]; then
    pass initramfs-closure 'root storage, VC4/V3D and systemd userspace present'
  else
    fail initramfs-closure "$MISSING_INITRAMFS required entries absent"
  fi

  EARLY_CUSTOM=0
  for module in "${CUSTOM_MODULES[@]}"; do
    MATCH_COUNT=$(grep -Ec "/${module}\.ko(\.|$)" "$INITRAMFS_LIST")
    EARLY_CUSTOM=$((EARLY_CUSTOM + MATCH_COUNT))
  done
  if [[ $EARLY_CUSTOM -eq 0 ]]; then
    warn early-uconsole-modules 'custom panel/power/audio modules load after root; early panel is unproven'
  else
    pass early-uconsole-modules "$EARLY_CUSTOM custom module entries embedded"
  fi
  pass initramfs-sha256 "$(sha256sum "$ROOT/boot/initramfs-linux.img" | awk '{print $1}')"
else
  fail initramfs-inspection 'lsinitcpio could not inspect the exact image'
fi

WIFI_FILES=(
  /usr/lib/firmware/brcm/brcmfmac43455-sdio.bin
  /usr/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob
  /usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-compute-module.txt
)
FIRMWARE_FAILURES=0
for path in "${WIFI_FILES[@]}"; do
  if [[ ! -e "$ROOT$path" ]]; then
    FIRMWARE_FAILURES=$((FIRMWARE_FAILURES + 1))
    printf '       missing Wi-Fi firmware: %s\n' "$path" >&2
  fi
done
if [[ ! -s "$ROOT/usr/lib/firmware/updates/brcm/BCM4345C0.hcd" ]]; then
  FIRMWARE_FAILURES=$((FIRMWARE_FAILURES + 1))
  printf '       missing Bluetooth firmware: /usr/lib/firmware/updates/brcm/BCM4345C0.hcd\n' >&2
fi
if [[ $FIRMWARE_FAILURES -eq 0 ]]; then
  pass radio-firmware 'CM5 CYW43455 Wi-Fi/NVRAM and BCM4345C0 Bluetooth payloads present'
else
  fail radio-firmware "$FIRMWARE_FAILURES required firmware paths absent"
fi

if [[ $FAILURES -eq 0 ]]; then
  printf '[PASS] %-24s failures=0 warnings=%s; no hardware probe or accelerated render claimed\n' summary "$WARNINGS"
  exit 0
fi

printf '[FAIL] %-24s failures=%s warnings=%s\n' summary "$FAILURES" "$WARNINGS" >&2
exit 1
