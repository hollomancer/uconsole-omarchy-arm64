#!/usr/bin/env bash

# The hardware-domain tripwire for Phase 6 updates.
#
# Every file under /boot — kernel, initramfs, CM5 DTBs, uConsole overlays,
# config.txt, cmdline.txt, firmware — belongs to the hardware domain and is
# owned by the project's hardware package. A base or desktop update that
# changes any of them is a defect, not a preference, so this check turns that
# from a review question into a mechanical one.
#
# Capture before a transaction, compare after:
#
#   check-boot-manifest.sh --capture --root /mnt/uconsole-root --output before.manifest
#   ... apply the transaction ...
#   check-boot-manifest.sh --compare --baseline before.manifest --root /mnt/uconsole-root
#
# Exit codes are the contract:
#   0  boot is byte-identical, or a hardware transition was explicitly approved
#   1  the gate fired: /boot changed
#   2  usage, input or environment error
#
# --baseline also accepts the JSON manifest build-image.sh embeds at
# /boot/uconsole-build-manifest.json, so an updated root can be compared
# against exactly what its image shipped.
#
# This command is read-only. It never writes into a root and never repairs a
# difference it finds.

set -u
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=scripts/lib/install-common.sh
source "$SCRIPT_DIR/lib/install-common.sh"

ACTION=''
ROOT=''
OUTPUT=''
BASELINE=''
CANDIDATE=''
ALLOW_TRANSITION=0

# The manifest build-image.sh embeds is itself a build product and changes on
# every build, so comparing it would report a difference on every run.
MANIFEST_BASENAME='uconsole-build-manifest.json'

usage() {
  printf '%s\n' \
    'Usage: check-boot-manifest.sh --capture  --root DIR [--output FILE]' \
    '       check-boot-manifest.sh --compare  --baseline FILE (--root DIR | --candidate FILE)' \
    '                                        [--allow-hardware-transition]' \
    '' \
    'Captures or compares the hardware-domain boot file set.' \
    '--baseline accepts either a captured manifest or the JSON manifest' \
    'build-image.sh embeds at /boot/uconsole-build-manifest.json.' \
    '' \
    'Exit 0 identical or approved, 1 the gate fired, 2 input error.' \
    'Read-only: no root is ever modified.'
}

set_action() {
  local requested=$1
  [[ -z "$ACTION" || "$ACTION" == "$requested" ]] || install_common_die 'choose exactly one action'
  ACTION=$requested
}

while (($# > 0)); do
  case "$1" in
    --capture) set_action capture; shift ;;
    --compare) set_action compare; shift ;;
    --root) (($# >= 2)) || install_common_die '--root requires a directory'; ROOT=$2; shift 2 ;;
    --output) (($# >= 2)) || install_common_die '--output requires a file'; OUTPUT=$2; shift 2 ;;
    --baseline) (($# >= 2)) || install_common_die '--baseline requires a file'; BASELINE=$2; shift 2 ;;
    --candidate) (($# >= 2)) || install_common_die '--candidate requires a file'; CANDIDATE=$2; shift 2 ;;
    --allow-hardware-transition) ALLOW_TRANSITION=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) install_common_die "unknown option: $1" ;;
  esac
done

[[ -n "$ACTION" ]] || { usage >&2; install_common_die 'choose --capture or --compare'; }

# Render a root's /boot as a deterministic, sorted, greppable table. The
# uconsole-build-manifest.json is excluded exactly as build-image.sh excludes it
# when generating that file, so the two views describe the same file set.
capture_root() {
  local root=$1
  local boot="$root/boot"
  [[ -d "$boot" && ! -L "$boot" ]] || install_common_die "root has no boot directory: $boot"

  local listing
  listing=$(find "$boot" -type f ! -name "$MANIFEST_BASENAME" -print | LC_ALL=C sort) ||
    install_common_die 'unable to list boot files'

  # A symlink under /boot would let the recorded digest and the byte the
  # firmware actually reads disagree, so refuse rather than resolve it.
  local links
  links=$(find "$boot" -type l -print | LC_ALL=C sort) || install_common_die 'unable to inspect boot for symlinks'
  [[ -z "$links" ]] || install_common_die "boot contains symbolic links, which the hardware domain forbids: $(printf '%s' "$links" | tr '\n' ' ')"

  local boot_file relative digest size
  while IFS= read -r boot_file; do
    [[ -n "$boot_file" ]] || continue
    relative=${boot_file#"$boot/"}
    digest=$(install_common_sha256 "$boot_file") || install_common_die "unable to hash boot file: $relative"
    size=$(stat -c '%s' "$boot_file" 2>/dev/null || stat -f '%z' "$boot_file") ||
      install_common_die "unable to size boot file: $relative"
    printf '%s  %s  %s\n' "$digest" "$size" "$relative"
  done <<< "$listing"
}

# Read either manifest form into the same three-column table.
read_manifest() {
  local path=$1
  install_common_require_file 'manifest' "$path"

  if head -n 1 "$path" | grep -Fq '{'; then
    # build-image.sh writes one JSON object per boot file and rejects any
    # filename containing a quote, backslash or newline at write time, so a
    # line-oriented read of that known shape is safe here.
    local extracted
    extracted=$(sed -n 's/.*{"path": "\(.*\)", "size": \([0-9]*\), "sha256": "\([0-9a-f]*\)"}.*/\3  \2  \1/p' "$path") ||
      install_common_die "unable to parse JSON manifest: $path"
    [[ -n "$extracted" ]] || install_common_die "JSON manifest contains no boot files: $path"
    printf '%s\n' "$extracted" | LC_ALL=C sort -k3
    return 0
  fi

  grep -v '^#' "$path" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -k3
}

if [[ "$ACTION" == 'capture' ]]; then
  ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
  BODY=$(capture_root "$ROOT") || exit 2
  COUNT=$(printf '%s\n' "$BODY" | grep -c . || true)
  [[ "$COUNT" -gt 0 ]] || install_common_die 'boot directory contains no files'
  ROLLUP=$(printf '%s\n' "$BODY" | sha256sum | awk '{print $1}')

  RENDERED=$(printf '# uconsole boot manifest v1\n# sha256  size  path\n# files=%s rollup=%s\n%s\n' "$COUNT" "$ROLLUP" "$BODY")
  if [[ -n "$OUTPUT" ]]; then
    [[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || install_common_die "refusing existing output path: $OUTPUT"
    printf '%s\n' "$RENDERED" > "$OUTPUT" || install_common_die "unable to write manifest: $OUTPUT"
    chmod 0644 "$OUTPUT" || install_common_die 'unable to set manifest mode'
    printf '[PASS] boot manifest        files=%s rollup=%s\n' "$COUNT" "$ROLLUP"
    printf '[PASS] written              %s\n' "$OUTPUT"
  else
    printf '%s\n' "$RENDERED"
  fi
  exit 0
fi

# --compare
[[ -n "$BASELINE" ]] || install_common_die '--compare requires --baseline'
if [[ -n "$ROOT" && -n "$CANDIDATE" ]]; then
  install_common_die 'choose either --root or --candidate, not both'
fi

BEFORE=$(read_manifest "$BASELINE") || exit 2

if [[ -n "$CANDIDATE" ]]; then
  AFTER=$(read_manifest "$CANDIDATE") || exit 2
  CANDIDATE_LABEL="$CANDIDATE"
elif [[ -n "$ROOT" ]]; then
  ROOT=$(install_common_require_offline_arch_root "$ROOT") || exit 2
  AFTER=$(capture_root "$ROOT" | LC_ALL=C sort -k3) || exit 2
  CANDIDATE_LABEL="$ROOT/boot"
else
  install_common_die '--compare requires --root or --candidate'
fi

BEFORE_COUNT=$(printf '%s\n' "$BEFORE" | grep -c . || true)
AFTER_COUNT=$(printf '%s\n' "$AFTER" | grep -c . || true)

# Compare by path so a changed file reads as "changed" rather than as an
# unrelated add plus remove.
BEFORE_PATHS=$(printf '%s\n' "$BEFORE" | awk '{ $1=""; $2=""; sub(/^  /, ""); print }' | LC_ALL=C sort)
AFTER_PATHS=$(printf '%s\n' "$AFTER" | awk '{ $1=""; $2=""; sub(/^  /, ""); print }' | LC_ALL=C sort)

ADDED=$(LC_ALL=C comm -13 <(printf '%s\n' "$BEFORE_PATHS") <(printf '%s\n' "$AFTER_PATHS"))
REMOVED=$(LC_ALL=C comm -23 <(printf '%s\n' "$BEFORE_PATHS") <(printf '%s\n' "$AFTER_PATHS"))
COMMON=$(LC_ALL=C comm -12 <(printf '%s\n' "$BEFORE_PATHS") <(printf '%s\n' "$AFTER_PATHS"))

CHANGED=''
while IFS= read -r shared_path; do
  [[ -n "$shared_path" ]] || continue
  before_digest=$(printf '%s\n' "$BEFORE" | awk -v want="$shared_path" '{ p=$0; sub(/^[^ ]+  [^ ]+  /, "", p); if (p == want) { print $1; exit } }')
  after_digest=$(printf '%s\n' "$AFTER" | awk -v want="$shared_path" '{ p=$0; sub(/^[^ ]+  [^ ]+  /, "", p); if (p == want) { print $1; exit } }')
  [[ "$before_digest" == "$after_digest" ]] || CHANGED+="$shared_path"$'\n'
done <<< "$COMMON"
CHANGED=${CHANGED%$'\n'}

ADDED_COUNT=$(printf '%s\n' "$ADDED" | grep -c . || true)
REMOVED_COUNT=$(printf '%s\n' "$REMOVED" | grep -c . || true)
CHANGED_COUNT=$(printf '%s\n' "$CHANGED" | grep -c . || true)
DIFF_TOTAL=$((ADDED_COUNT + REMOVED_COUNT + CHANGED_COUNT))

printf '%s\n' \
  "[INFO] baseline             $BASELINE ($BEFORE_COUNT files)" \
  "[INFO] candidate            $CANDIDATE_LABEL ($AFTER_COUNT files)"

if [[ $DIFF_TOTAL -eq 0 ]]; then
  printf '[PASS] hardware domain      /boot is byte-identical across %s files\n' "$BEFORE_COUNT"
  exit 0
fi

print_group() {
  local label=$1
  local body=$2
  [[ -n "$body" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf '  %s %s\n' "$label" "$entry"
  done <<< "$body"
}

if [[ $ALLOW_TRANSITION -eq 1 ]]; then
  printf '[WARN] hardware domain      %s boot file(s) differ; approved by --allow-hardware-transition\n' "$DIFF_TOTAL"
else
  printf '[FAIL] hardware domain      %s boot file(s) differ and no hardware transition was approved\n' "$DIFF_TOTAL"
fi
print_group 'changed:' "$CHANGED"
print_group 'added:  ' "$ADDED"
print_group 'removed:' "$REMOVED"

if [[ $ALLOW_TRANSITION -eq 1 ]]; then
  printf '\nRecord this transition against an approved hardware package change.\n'
  exit 0
fi

printf '%s\n' \
  '' \
  'A base or desktop update must not modify the hardware domain. Re-run the' \
  'transaction without the step that touched /boot, or, if this is a deliberate' \
  'hardware package transition, repeat with --allow-hardware-transition.'
exit 1
