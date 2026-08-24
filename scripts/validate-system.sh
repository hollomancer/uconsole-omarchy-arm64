#!/usr/bin/env bash

# Read-only validation for the Arch Linux ARM -> hardware -> Hyprland ->
# Omarchy stack. It never installs packages, changes services or writes boot
# configuration. Fixture mode is for deterministic tests and captured systems.

set -u
set -o pipefail

SCRIPT_DIR=""
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve script directory\n' >&2
  exit 2
fi
REPO_ROOT=""
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

PHASE="hardware"
ROOT="/"
FIXTURE=""
PACKAGES_FILE="$REPO_ROOT/config/arm64-overrides/omarchy-core.packages"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
PROBE_OUTPUT=""
PROBE_STATUS=0

usage() {
  printf '%s\n' \
    'Usage: validate-system.sh [options]' \
    '' \
    'Options:' \
    '  --phase hardware|hyprland|omarchy  Select enforced layer (default: hardware)' \
    '  --root PATH                        Inspect an alternate mounted root' \
    '  --fixture PATH                     Use captured command/filesystem fixtures' \
    '  --packages-file PATH               Expected core package names, one per line' \
    '  --help                             Show this help' \
    '' \
    'Exit status is 1 when any enforced check is FAIL, 0 otherwise, and 2 for usage errors.'
}

die_usage() {
  printf 'ERROR: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --phase)
      (($# >= 2)) || die_usage '--phase requires a value'
      PHASE=$2
      shift 2
      ;;
    --root)
      (($# >= 2)) || die_usage '--root requires a path'
      ROOT=$2
      shift 2
      ;;
    --fixture)
      (($# >= 2)) || die_usage '--fixture requires a path'
      FIXTURE=$2
      shift 2
      ;;
    --packages-file)
      (($# >= 2)) || die_usage '--packages-file requires a path'
      PACKAGES_FILE=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

case "$PHASE" in
  hardware|hyprland|omarchy) ;;
  *) die_usage "invalid phase: $PHASE" ;;
esac

if [[ -n "$FIXTURE" ]]; then
  [[ -d "$FIXTURE" ]] || die_usage "fixture directory does not exist: $FIXTURE"
  ROOT="$FIXTURE/root"
fi
[[ -d "$ROOT" ]] || die_usage "root directory does not exist: $ROOT"
[[ -f "$PACKAGES_FILE" ]] || die_usage "package manifest does not exist: $PACKAGES_FILE"

phase_at_least() {
  local wanted=$1
  case "$wanted:$PHASE" in
    hardware:*) return 0 ;;
    hyprland:hyprland|hyprland:omarchy) return 0 ;;
    omarchy:omarchy) return 0 ;;
    *) return 1 ;;
  esac
}

one_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-220
}

report() {
  local level=$1
  local name=$2
  local detail=""
  detail=$(one_line "$3")
  case "$level" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    *) printf 'Internal error: invalid result level %s\n' "$level" >&2; exit 2 ;;
  esac
  printf '[%s] %-24s %s\n' "$level" "$name" "$detail"
}

run_probe() {
  local name=$1
  local status_file=""
  local stdout_file=""
  shift

  PROBE_OUTPUT=""
  PROBE_STATUS=0
  if [[ -n "$FIXTURE" ]]; then
    stdout_file="$FIXTURE/commands/$name.stdout"
    status_file="$FIXTURE/commands/$name.status"
    if [[ -f "$stdout_file" ]]; then
      PROBE_OUTPUT=$(<"$stdout_file")
    fi
    if [[ -f "$status_file" ]]; then
      PROBE_STATUS=$(<"$status_file")
    elif [[ -f "$stdout_file" ]]; then
      PROBE_STATUS=0
    else
      PROBE_STATUS=127
    fi
    return
  fi

  if ! command -v "$1" >/dev/null 2>&1; then
    PROBE_STATUS=127
    return
  fi
  PROBE_OUTPUT=$("$@" 2>&1)
  PROBE_STATUS=$?
}

read_text() {
  local path=$1
  if [[ ! -r "$path" ]]; then
    return 1
  fi
  tr -d '\000' < "$path"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

collect_dt_compatibles() {
  local dt_root="$ROOT/proc/device-tree"
  local file=""
  local value=""
  [[ -d "$dt_root" ]] || return 1
  while IFS= read -r file; do
    value=$(read_text "$file")
    printf '%s\n' "$value"
  done < <(find "$dt_root" -type f -name compatible -print 2>/dev/null)
}

printf 'uConsole CM5 validation — phase=%s root=%s\n\n' "$PHASE" "$ROOT"

run_probe uname_m uname -m
if [[ $PROBE_STATUS -eq 0 && "$PROBE_OUTPUT" == "aarch64" ]]; then
  report PASS architecture 'aarch64'
else
  report FAIL architecture "expected aarch64; observed ${PROBE_OUTPUT:-unavailable}"
fi

run_probe uname_r uname -r
if [[ $PROBE_STATUS -eq 0 && -n "$PROBE_OUTPUT" ]]; then
  report PASS kernel "$PROBE_OUTPUT"
else
  report FAIL kernel 'kernel version unavailable'
fi

run_probe getconf_pagesize getconf PAGESIZE
case "$PROBE_STATUS:$PROBE_OUTPUT" in
  0:4096) report PASS page-size '4096 bytes (4 KiB)' ;;
  0:16384) report PASS page-size '16384 bytes (16 KiB; test every proprietary/native binary)' ;;
  127:*) report WARN page-size 'getconf unavailable' ;;
  *) report WARN page-size "unexpected result: ${PROBE_OUTPUT:-unavailable}" ;;
esac

MODEL=""
if MODEL=$(read_text "$ROOT/proc/device-tree/model"); then
  MODEL_LOWER=$(lower "$MODEL")
  if [[ "$MODEL_LOWER" == *"compute module 5"* || "$MODEL_LOWER" == *"cm5"* ]]; then
    report PASS device-tree-model "$MODEL"
  else
    report FAIL device-tree-model "expected CM5; observed $MODEL"
  fi
else
  report FAIL device-tree-model 'model node is unreadable'
fi

DT_COMPAT=""
DT_COMPAT=$(collect_dt_compatibles)
DT_COMPAT_LOWER=$(lower "$DT_COMPAT")
if [[ "$DT_COMPAT_LOWER" == *"clockwork"* || "$DT_COMPAT_LOWER" == *"cwu50"* || "$DT_COMPAT_LOWER" == *"ocp8178"* || "$DT_COMPAT_LOWER" == *"axp228"* ]]; then
  report PASS device-tree-uconsole 'uConsole-specific compatible node found'
else
  report WARN device-tree-uconsole 'no uConsole-specific compatible string found; inspect the live DT/overlay symbols'
fi

MODULES=""
if MODULES=$(read_text "$ROOT/proc/modules"); then
  if [[ "$MODULES" == *$'vc4 '* && "$MODULES" == *$'v3d '* ]]; then
    report PASS gpu-kernel-driver 'vc4 and v3d modules loaded'
  else
    report FAIL gpu-kernel-driver 'vc4 and/or v3d module is absent'
  fi
else
  report FAIL gpu-kernel-driver '/proc/modules is unreadable'
fi

if [[ -e "$ROOT/dev/dri/card0" && -e "$ROOT/dev/dri/renderD128" ]]; then
  report PASS drm-nodes 'card0 and renderD128 present'
else
  report FAIL drm-nodes 'required card0/renderD128 pair is absent'
fi

run_probe lspci lspci -nnk
if [[ $PROBE_STATUS -eq 0 && -n "$PROBE_OUTPUT" ]]; then
  report PASS pci-inventory "$PROBE_OUTPUT"
else
  report WARN pci-inventory 'lspci unavailable or empty; Pi GPU/display devices are platform devices, so DT/DRM remains authoritative'
fi

run_probe glxinfo glxinfo -B
GLX_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN opengl-acceleration 'glxinfo unavailable or no captured probe'
elif [[ "$GLX_LOWER" == *"llvmpipe"* || "$GLX_LOWER" == *"softpipe"* ]]; then
  report FAIL opengl-acceleration "software renderer detected: $PROBE_OUTPUT"
elif [[ $PROBE_STATUS -eq 0 && ( "$GLX_LOWER" == *"v3d"* || "$GLX_LOWER" == *"broadcom"* ) ]]; then
  report PASS opengl-acceleration "$PROBE_OUTPUT"
elif [[ $PROBE_STATUS -ne 0 ]]; then
  report WARN opengl-acceleration "probe unavailable outside a graphical session: ${PROBE_OUTPUT:-no output}"
else
  report WARN opengl-acceleration "renderer is not recognized as V3D: $PROBE_OUTPUT"
fi

run_probe vulkaninfo vulkaninfo --summary
VULKAN_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN vulkan-acceleration 'vulkaninfo unavailable or no captured probe'
elif [[ "$VULKAN_LOWER" == *"lavapipe"* || "$VULKAN_LOWER" == *"llvmpipe"* || "$VULKAN_LOWER" == *"software"* ]]; then
  report FAIL vulkan-acceleration "software renderer detected: $PROBE_OUTPUT"
elif [[ $PROBE_STATUS -eq 0 && ( "$VULKAN_LOWER" == *"v3dv"* || "$VULKAN_LOWER" == *"broadcom"* ) ]]; then
  report PASS vulkan-acceleration "$PROBE_OUTPUT"
elif [[ $PROBE_STATUS -ne 0 ]]; then
  report WARN vulkan-acceleration "probe failed: ${PROBE_OUTPUT:-no output}"
else
  report WARN vulkan-acceleration "device is not recognized as V3DV: $PROBE_OUTPUT"
fi

CONNECTED=""
NATIVE_MODE=""
for STATUS_FILE in "$ROOT"/sys/class/drm/*/status; do
  [[ -f "$STATUS_FILE" ]] || continue
  STATUS=$(read_text "$STATUS_FILE")
  if [[ "$STATUS" == "connected" ]]; then
    CONNECTOR=${STATUS_FILE%/status}
    CONNECTOR=${CONNECTOR##*/}
    CONNECTED="$CONNECTED $CONNECTOR"
    MODES_FILE="${STATUS_FILE%/status}/modes"
    if [[ -r "$MODES_FILE" ]]; then
      MODES=$(read_text "$MODES_FILE")
      if [[ "$MODES" == *"720x1280"* || "$MODES" == *"1280x720"* ]]; then
        NATIVE_MODE="$NATIVE_MODE $CONNECTOR"
      fi
    fi
  fi
done
if [[ -n "$NATIVE_MODE" ]]; then
  report PASS internal-display "connected at native panel mode:$NATIVE_MODE"
elif [[ -n "$CONNECTED" ]]; then
  report WARN internal-display "connected connector lacks expected 720x1280/1280x720 mode:$CONNECTED"
else
  report FAIL internal-display 'no connected DRM connector found'
fi

BACKLIGHT_FOUND=0
for BACKLIGHT in "$ROOT"/sys/class/backlight/*; do
  [[ -d "$BACKLIGHT" ]] || continue
  BACKLIGHT_FOUND=1
done
if [[ $BACKLIGHT_FOUND -eq 1 ]]; then
  report PASS backlight 'backlight class device present'
else
  report FAIL backlight 'no backlight class device present'
fi

run_probe aplay aplay -l
APLAY_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN audio-alsa 'aplay unavailable or no captured probe'
elif [[ $PROBE_STATUS -eq 0 && "$APLAY_LOWER" == *"card "* && "$APLAY_LOWER" != *"no soundcards"* ]]; then
  report PASS audio-alsa "$PROBE_OUTPUT"
else
  report FAIL audio-alsa "no ALSA card found: ${PROBE_OUTPUT:-no output}"
fi

run_probe wpctl wpctl status
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN audio-pipewire 'wpctl unavailable or no captured probe'
elif [[ $PROBE_STATUS -eq 0 && "$PROBE_OUTPUT" == *"Audio"* ]]; then
  report PASS audio-pipewire "$PROBE_OUTPUT"
else
  report WARN audio-pipewire "PipeWire session is not confirmed: ${PROBE_OUTPUT:-no output}"
fi

run_probe nmcli nmcli -t -f DEVICE,TYPE,STATE device
NMCLI_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN networking 'nmcli unavailable or no captured probe'
elif [[ $PROBE_STATUS -eq 0 && "$NMCLI_LOWER" == *":connected"* ]]; then
  report PASS networking "$PROBE_OUTPUT"
else
  report FAIL networking "no connected NetworkManager device: ${PROBE_OUTPUT:-no output}"
fi

run_probe iw iw dev
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN wifi 'iw unavailable or no captured probe'
elif [[ $PROBE_STATUS -eq 0 && "$PROBE_OUTPUT" == *"Interface"* ]]; then
  report PASS wifi "$PROBE_OUTPUT"
else
  report FAIL wifi "wireless interface not found: ${PROBE_OUTPUT:-no output}"
fi

run_probe bluetoothctl bluetoothctl show
BT_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN bluetooth 'bluetoothctl unavailable or no captured probe'
elif [[ $PROBE_STATUS -eq 0 && "$BT_LOWER" == *"controller"* && "$BT_LOWER" == *"powered: yes"* ]]; then
  report PASS bluetooth "$PROBE_OUTPUT"
elif [[ $PROBE_STATUS -eq 0 && "$BT_LOWER" == *"controller"* ]]; then
  report WARN bluetooth "controller present but not powered: $PROBE_OUTPUT"
else
  report FAIL bluetooth "controller not found: ${PROBE_OUTPUT:-no output}"
fi

BATTERY_DETAIL=""
for TYPE_FILE in "$ROOT"/sys/class/power_supply/*/type; do
  [[ -f "$TYPE_FILE" ]] || continue
  TYPE=$(read_text "$TYPE_FILE")
  if [[ "$TYPE" == "Battery" ]]; then
    SUPPLY=${TYPE_FILE%/type}
    NAME=${SUPPLY##*/}
    CAPACITY='unknown'
    BATTERY_STATUS='unknown'
    if [[ -r "$SUPPLY/capacity" ]]; then CAPACITY=$(read_text "$SUPPLY/capacity"); fi
    if [[ -r "$SUPPLY/status" ]]; then BATTERY_STATUS=$(read_text "$SUPPLY/status"); fi
    BATTERY_DETAIL="$NAME capacity=$CAPACITY status=$BATTERY_STATUS"
    break
  fi
done
if [[ -n "$BATTERY_DETAIL" ]]; then
  report PASS battery "$BATTERY_DETAIL"
else
  report FAIL battery 'no Battery power_supply found'
fi

INPUTS=""
if INPUTS=$(read_text "$ROOT/proc/bus/input/devices"); then
  if [[ "$INPUTS" == *"kbd"* && "$INPUTS" == *"mouse"* ]]; then
    report PASS input-devices 'keyboard and pointer handlers present'
  else
    report FAIL input-devices 'keyboard and/or pointer handler absent'
  fi
else
  report FAIL input-devices '/proc/bus/input/devices is unreadable'
fi

run_probe hyprctl hyprctl systeminfo
HYPR_STATUS=$PROBE_STATUS
HYPR_OUTPUT=$PROBE_OUTPUT
if [[ $HYPR_STATUS -eq 0 && -n "$HYPR_OUTPUT" ]]; then
  report PASS hyprland "$HYPR_OUTPUT"
elif phase_at_least hyprland; then
  report FAIL hyprland "required session unavailable: ${HYPR_OUTPUT:-no output}"
else
  report WARN hyprland 'not required during hardware phase'
fi

run_probe hypr_monitors hyprctl monitors all
MONITOR_LOWER=$(lower "$PROBE_OUTPUT")
if [[ $PROBE_STATUS -eq 0 && ( "$MONITOR_LOWER" == *"720x1280"* || "$MONITOR_LOWER" == *"1280x720"* ) && ( "$MONITOR_LOWER" == *"transform: 1"* || "$MONITOR_LOWER" == *"transform: 3"* ) ]]; then
  report PASS display-orientation "$PROBE_OUTPUT"
elif [[ $PROBE_STATUS -eq 0 ]]; then
  report WARN display-orientation "native mode plus 90/270-degree transform not confirmed: $PROBE_OUTPUT"
else
  report WARN display-orientation 'requires a running Hyprland session'
fi

run_probe omarchy_version omarchy-version
if [[ $PROBE_STATUS -eq 0 && -n "$PROBE_OUTPUT" ]]; then
  report PASS omarchy-userland "$PROBE_OUTPUT"
elif phase_at_least omarchy; then
  report FAIL omarchy-userland "required Omarchy command unavailable: ${PROBE_OUTPUT:-no output}"
else
  report WARN omarchy-userland 'not required before the Omarchy phase'
fi

run_probe pacman_q pacman -Qq
MISSING=""
if [[ $PROBE_STATUS -eq 127 ]]; then
  report WARN omarchy-core-packages 'pacman unavailable or no captured package inventory'
else
  while IFS= read -r PACKAGE; do
    [[ -n "$PACKAGE" ]] || continue
    [[ "$PACKAGE" == \#* ]] && continue
    if ! printf '%s\n' "$PROBE_OUTPUT" | grep -Fqx -- "$PACKAGE"; then
      MISSING="$MISSING $PACKAGE"
    fi
  done < "$PACKAGES_FILE"
  if [[ -z "$MISSING" ]]; then
    report PASS omarchy-core-packages 'all expected ARM core packages installed'
  elif phase_at_least omarchy; then
    report FAIL omarchy-core-packages "missing:$MISSING"
  else
    report WARN omarchy-core-packages "not yet required; missing:$MISSING"
  fi
fi

printf '\nSummary: PASS=%d WARN=%d FAIL=%d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
exit 0
