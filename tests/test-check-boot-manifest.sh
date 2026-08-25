#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
CHECKER="$REPO_ROOT/scripts/check-boot-manifest.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-boot-manifest-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-boot-manifest-test.*|/private/tmp/uconsole-boot-manifest-test.*|/var/folders/*/T/uconsole-boot-manifest-test.*|/private/var/folders/*/T/uconsole-boot-manifest-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

make_root() {
  local root=$1
  mkdir -p "$root/etc" "$root/boot/overlays" "$root/var/lib/pacman/local"
  printf '%s\n' 'NAME="Arch Linux ARM"' 'ID=archarm' > "$root/etc/os-release"
  printf 'kernel bytes\n' > "$root/boot/kernel8.img"
  printf 'dtb bytes\n' > "$root/boot/bcm2712-rpi-cm5-cm5io.dtb"
  printf 'overlay bytes\n' > "$root/boot/overlays/uconsole-cm5-base.dtbo"
  # Boot filenames containing whitespace: field-splitting or a
  # whitespace-collapsing regex fails to match such a path against its own
  # digest, and two empty lookups compare equal, so a tampered file reads as
  # unchanged. That is a fail-open in the gate's only job.
  printf 'two space bytes\n' > "$root/boot/odd  name.dtbo"
  printf 'tabbed bytes\n' > "$root/boot/tab$(printf '\t')name.dtbo"
  printf 'dtparam=ant2\n' > "$root/boot/config.txt"
  printf 'console=serial0,115200 console=tty1\n' > "$root/boot/cmdline.txt"
}

ROOT="$TEST_TMP/root"
make_root "$ROOT"
BEFORE="$TEST_TMP/before.manifest"

# Capture writes a deterministic manifest and does not touch the root.
ROOT_SHA_BEFORE=$(find "$ROOT" -type f -exec sha256sum {} \; | LC_ALL=C sort | sha256sum)
"$CHECKER" --capture --root "$ROOT" --output "$BEFORE" >/dev/null || { printf 'Expected capture to pass\n' >&2; exit 1; }
[[ -f "$BEFORE" ]] || { printf 'Capture did not write a manifest\n' >&2; exit 1; }
[[ "$(find "$ROOT" -type f -exec sha256sum {} \; | LC_ALL=C sort | sha256sum)" == "$ROOT_SHA_BEFORE" ]] || {
  printf 'Capture modified the root\n' >&2; exit 1; }
grep -Fq 'kernel8.img' "$BEFORE" || { printf 'Manifest is missing the kernel\n' >&2; exit 1; }
grep -Fq 'overlays/uconsole-cm5-base.dtbo' "$BEFORE" || { printf 'Manifest is missing the overlay\n' >&2; exit 1; }

# Capture is reproducible.
SECOND="$TEST_TMP/second.manifest"
"$CHECKER" --capture --root "$ROOT" --output "$SECOND" >/dev/null || { printf 'Expected second capture to pass\n' >&2; exit 1; }
cmp -s "$BEFORE" "$SECOND" || { printf 'Capture is not reproducible\n' >&2; exit 1; }

# Refuse to clobber an existing output.
STATUS=0; "$CHECKER" --capture --root "$ROOT" --output "$BEFORE" >/dev/null 2>&1 || STATUS=$?
[[ $STATUS -eq 2 ]] || { printf 'Expected existing output to be refused; got %s\n' "$STATUS" >&2; exit 1; }

# Unchanged boot passes the gate.
"$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" >/dev/null || { printf 'Expected identical boot to pass\n' >&2; exit 1; }

expect_gate_fires() {
  local label=$1
  shift
  local status=0
  "$CHECKER" "$@" >/dev/null 2>&1
  status=$?
  [[ $status -eq 1 ]] || { printf 'Expected %s to fire the gate with status 1; got %s\n' "$label" "$status" >&2; exit 1; }
}

# A modified kernel fires the gate and is reported as changed, not add+remove.
printf 'tampered kernel\n' > "$ROOT/boot/kernel8.img"
expect_gate_fires 'modified kernel' --compare --baseline "$BEFORE" --root "$ROOT"
OUT=$("$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" 2>&1 || true)
printf '%s\n' "$OUT" | grep -Fq 'changed: kernel8.img' || { printf 'Modified kernel not reported as changed:\n%s\n' "$OUT" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -Fq 'added:' && { printf 'Modified kernel wrongly reported as added:\n%s\n' "$OUT" >&2; exit 1; }

# The same difference is allowed through only with the explicit flag.
"$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" --allow-hardware-transition >/dev/null || {
  printf 'Expected approved hardware transition to pass\n' >&2; exit 1; }
OUT=$("$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" --allow-hardware-transition 2>&1)
printf '%s\n' "$OUT" | grep -Fq 'WARN' || { printf 'Approved transition did not warn:\n%s\n' "$OUT" >&2; exit 1; }
printf 'kernel bytes\n' > "$ROOT/boot/kernel8.img"

# Whitespace in a boot filename must not let a tampered file through.
printf 'TAMPERED\n' > "$ROOT/boot/odd  name.dtbo"
expect_gate_fires 'tampered two-space filename' --compare --baseline "$BEFORE" --root "$ROOT"
OUT=$("$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" 2>&1 || true)
printf '%s\n' "$OUT" | grep -Fq 'changed: odd  name.dtbo' || { printf 'Two-space filename not reported as changed:\n%s\n' "$OUT" >&2; exit 1; }
printf 'two space bytes\n' > "$ROOT/boot/odd  name.dtbo"

printf 'TAMPERED\n' > "$ROOT/boot/tab$(printf '\t')name.dtbo"
expect_gate_fires 'tampered tabbed filename' --compare --baseline "$BEFORE" --root "$ROOT"
printf 'tabbed bytes\n' > "$ROOT/boot/tab$(printf '\t')name.dtbo"
"$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" >/dev/null || { printf 'Expected restored whitespace files to pass\n' >&2; exit 1; }

# An added overlay fires the gate.
printf 'new overlay\n' > "$ROOT/boot/overlays/extra.dtbo"
expect_gate_fires 'added overlay' --compare --baseline "$BEFORE" --root "$ROOT"
OUT=$("$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" 2>&1 || true)
printf '%s\n' "$OUT" | grep -Fq 'added:   overlays/extra.dtbo' || { printf 'Added overlay not reported:\n%s\n' "$OUT" >&2; exit 1; }
rm "$ROOT/boot/overlays/extra.dtbo"

# A removed DTB fires the gate.
mv "$ROOT/boot/bcm2712-rpi-cm5-cm5io.dtb" "$TEST_TMP/dtb"
expect_gate_fires 'removed DTB' --compare --baseline "$BEFORE" --root "$ROOT"
OUT=$("$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" 2>&1 || true)
printf '%s\n' "$OUT" | grep -Fq 'removed: bcm2712-rpi-cm5-cm5io.dtb' || { printf 'Removed DTB not reported:\n%s\n' "$OUT" >&2; exit 1; }
mv "$TEST_TMP/dtb" "$ROOT/boot/bcm2712-rpi-cm5-cm5io.dtb"
"$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" >/dev/null || { printf 'Expected restored boot to pass again\n' >&2; exit 1; }

# The JSON manifest build-image.sh embeds is accepted as a baseline, and the
# manifest file itself is excluded from both views so it never self-reports.
JSON="$TEST_TMP/uconsole-build-manifest.json"
{
  printf '{\n  "schema": 1,\n  "boot_files": [\n'
  first=1
  while read -r digest size path; do
    [[ -n "$digest" ]] || continue
    [[ $first -eq 1 ]] || printf ',\n'
    first=0
    printf '    {"path": "%s", "size": %s, "sha256": "%s"}' "$path" "$size" "$digest"
  done < <(grep -v '^#' "$BEFORE")
  printf '\n  ]\n}\n'
} > "$JSON"
"$CHECKER" --compare --baseline "$JSON" --root "$ROOT" >/dev/null || { printf 'Expected JSON baseline to pass\n' >&2; exit 1; }
printf 'tampered\n' > "$ROOT/boot/config.txt"
expect_gate_fires 'JSON baseline with modified config.txt' --compare --baseline "$JSON" --root "$ROOT"
printf 'dtparam=ant2\n' > "$ROOT/boot/config.txt"

# An embedded build manifest inside /boot must not itself count as a difference.
cp "$JSON" "$ROOT/boot/uconsole-build-manifest.json"
"$CHECKER" --compare --baseline "$BEFORE" --root "$ROOT" >/dev/null || {
  printf 'Embedded build manifest was wrongly treated as a boot change\n' >&2; exit 1; }
rm "$ROOT/boot/uconsole-build-manifest.json"

# Manifest-to-manifest comparison works without a root.
AFTER="$TEST_TMP/after.manifest"
printf 'tampered\n' > "$ROOT/boot/cmdline.txt"
"$CHECKER" --capture --root "$ROOT" --output "$AFTER" >/dev/null || { printf 'Expected capture of changed root to pass\n' >&2; exit 1; }
expect_gate_fires 'manifest-to-manifest difference' --compare --baseline "$BEFORE" --candidate "$AFTER"
printf 'console=serial0,115200 console=tty1\n' > "$ROOT/boot/cmdline.txt"

expect_rejected() {
  local label=$1
  shift
  local status=0
  "$CHECKER" "$@" >/dev/null 2>&1
  status=$?
  [[ $status -eq 2 ]] || { printf 'Expected %s to be rejected with status 2; got %s\n' "$label" "$status" >&2; exit 1; }
}

expect_rejected 'no action' --root "$ROOT"
expect_rejected 'both actions' --capture --compare --root "$ROOT"
expect_rejected 'compare without baseline' --compare --root "$ROOT"
expect_rejected 'root and candidate together' --compare --baseline "$BEFORE" --root "$ROOT" --candidate "$AFTER"
expect_rejected 'missing baseline file' --compare --baseline "$TEST_TMP/absent.manifest" --root "$ROOT"
expect_rejected 'unknown option' --capture --root "$ROOT" --wat

# A non-Arch root must stop at the root check rather than continue to a host
# path; exactly one error is what distinguishes the two.
mkdir -p "$TEST_TMP/not-a-root"
expect_rejected 'non-Arch root' --capture --root "$TEST_TMP/not-a-root"
BAD=$("$CHECKER" --capture --root "$TEST_TMP/not-a-root" 2>&1 || true)
BAD_ERRORS=$(printf '%s\n' "$BAD" | grep -c '^ERROR:')
[[ "$BAD_ERRORS" -eq 1 ]] || { printf 'Expected exactly one error for a rejected root; got %s:\n%s\n' "$BAD_ERRORS" "$BAD" >&2; exit 1; }

# A symlink under /boot is refused: the recorded digest and the byte the
# firmware reads could otherwise disagree.
ln -s kernel8.img "$ROOT/boot/kernel-link.img"
expect_rejected 'symlink under boot' --capture --root "$ROOT"
rm "$ROOT/boot/kernel-link.img"

printf 'check-boot-manifest tests: PASS\n'
