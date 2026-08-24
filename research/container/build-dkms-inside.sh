#!/usr/bin/env bash

# Runs only inside the pinned aarch64 Arch Linux ARM build container.

set -euo pipefail

: "${HEADER_NAME:?}"
: "${HEADERS_SHA256:?}"
: "${KERNEL_RELEASE:?}"
: "${SOURCE_COMMIT:?}"
: "${BUILDER_IMAGE:?}"

exec > >(tee /output/build.log) 2>&1

tar -xf "/input/$HEADER_NAME" -C /
BUILD_DIR="/usr/lib/modules/$KERNEL_RELEASE/build"
[[ -f "$BUILD_DIR/Makefile" ]] || { printf 'Missing kernel build tree: %s\n' "$BUILD_DIR" >&2; exit 1; }

mkdir /work
cp -R /source/dkms /work/dkms
mkdir /work/overlays

make -C "$BUILD_DIR" M=/work/dkms modules

MODULES=(
  panel-cwu50.ko
  ocp8178_bl.ko
  axp20x.ko
  axp20x-i2c.ko
  axp20x-regulator.ko
  axp20x_battery.ko
  axp20x_adc.ko
  snd-soc-simple-amplifier.ko
  axp20x-pek.ko
)

for module in "${MODULES[@]}"; do
  [[ -s "/work/dkms/$module" ]] || { printf 'Missing module: %s\n' "$module" >&2; exit 1; }
  FILE_INFO=$(file -b "/work/dkms/$module")
  [[ "$FILE_INFO" == *"ARM aarch64"* ]] || { printf 'Wrong ELF architecture for %s: %s\n' "$module" "$FILE_INFO" >&2; exit 1; }
  VERMAGIC=$(modinfo -F vermagic "/work/dkms/$module")
  [[ "$VERMAGIC" == "$KERNEL_RELEASE "* ]] || { printf 'Wrong vermagic for %s: %s\n' "$module" "$VERMAGIC" >&2; exit 1; }
  install -m 0644 "/work/dkms/$module" "/output/$module"
done

DTC="$BUILD_DIR/scripts/dtc/dtc"
[[ -x "$DTC" ]] || { printf 'Missing executable dtc in header package\n' >&2; exit 1; }
"$DTC" -@ -I dts -O dtb -o /work/overlays/uconsole-cm5-base.dtbo /source/overlay/uconsole-cm5-base-overlay.dts
"$DTC" -@ -I dts -O dtb -o /work/overlays/uconsole-audio-cm5.dtbo /source/overlay/uconsole-audio-cm5-overlay.dts
install -m 0644 /work/overlays/uconsole-cm5-base.dtbo /output/uconsole-cm5-base.dtbo
install -m 0644 /work/overlays/uconsole-audio-cm5.dtbo /output/uconsole-audio-cm5.dtbo

printf '%s\n' \
  "source_commit=$SOURCE_COMMIT" \
  "header_package=$HEADER_NAME" \
  "header_sha256=$HEADERS_SHA256" \
  "kernel_release=$KERNEL_RELEASE" \
  "builder_image=$BUILDER_IMAGE" \
  > /output/build-info.txt

pushd /output >/dev/null
sha256sum ./*.ko ./*.dtbo ./build-info.txt > SHA256SUMS
popd >/dev/null
