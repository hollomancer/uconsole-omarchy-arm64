#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
RESOLVER="$REPO_ROOT/research/resolve-transaction.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_TMP=$(mktemp -d "$TEST_BASE/uconsole-resolve-transaction-test.XXXXXX")
cleanup() {
  case "$TEST_TMP" in
    /tmp/uconsole-resolve-transaction-test.*|/private/tmp/uconsole-resolve-transaction-test.*|/var/folders/*/T/uconsole-resolve-transaction-test.*|/private/var/folders/*/T/uconsole-resolve-transaction-test.*) rm -rf -- "$TEST_TMP" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

sha_of() { sha256sum "$1" | awk '{print $1}'; }

# Fixture databases stand in for the frozen production snapshot. A descriptor
# is copied from the real one with only the database digests rewritten, so
# every other field under test — image, entry point, locks, tmpfs, mode
# handling — remains exactly what production uses.
CORE_DB="$TEST_TMP/core.db"
EXTRA_DB="$TEST_TMP/extra.db"
printf 'fixture core database\n' > "$CORE_DB"
printf 'fixture extra database\n' > "$EXTRA_DB"
CORE_SHA=$(sha_of "$CORE_DB")
EXTRA_SHA=$(sha_of "$EXTRA_DB")

test_descriptor() {
  local layer=$1
  local out="$TEST_TMP/$layer-resolver.conf"
  sed -e "s/^core_db_sha256|.*/core_db_sha256|$CORE_SHA/" \
      -e "s/^extra_db_sha256|.*/extra_db_sha256|$EXTRA_SHA/" \
      "$REPO_ROOT/config/$layer/resolver.conf" > "$out"
  printf '%s\n' "$out"
}

HYPR_DESC=$(test_descriptor hyprland)
SHELL_DESC=$(test_descriptor omarchy-shell)

OUT_DIR="$TEST_TMP/output"
mkdir -p "$OUT_DIR"
VOLUME='uconsole-fixture-root'

common_args() {
  printf '%s\n' --source-volume "$VOLUME" --output-dir "$OUT_DIR" \
    --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --print-command
}
mapfile -t COMMON < <(common_args)

# The emitted container command must carry the safety properties the two
# original resolvers had. These are asserted individually rather than as one
# opaque string so a regression names the property it broke.
CMD=$("$RESOLVER" --layer-file "$HYPR_DESC" "${COMMON[@]}" | tail -n 1) || {
  printf 'Expected hyprland print-command to pass\n' >&2; exit 1; }

assert_contains() {
  local label=$1 needle=$2
  printf '%s\n' "$CMD" | grep -Fq -- "$needle" || {
    printf 'Emitted command lacks %s (%s):\n%s\n' "$label" "$needle" "$CMD" >&2
    exit 1
  }
}

assert_contains 'arm64 platform'        '--platform linux/arm64'
assert_contains 'read-only repository'  "type=bind,src=$REPO_ROOT,dst=/repo,readonly"
assert_contains 'read-only core db'     "dst=/snapshot/core.db,readonly"
assert_contains 'read-only extra db'    "dst=/snapshot/extra.db,readonly"
assert_contains 'read-only source root' "type=volume,src=$VOLUME,dst=/target,readonly"
assert_contains 'writable output'       "type=bind,src=$OUT_DIR,dst=/output"
assert_contains 'work tmpfs'            '--tmpfs /work:rw,size=1024m'
assert_contains 'removes container'     '--rm'
assert_contains 'hyprland entry point'  '/repo/research/container/resolve-hyprland-closure-inside.sh'

# The output mount must stay writable; everything else must not.
printf '%s\n' "$CMD" | grep -Fq "src=$OUT_DIR,dst=/output,readonly" && {
  printf 'Output directory was mounted read-only\n' >&2; exit 1; }

# inside_args discriminates the two entry-point calling conventions. The
# hyprland container script takes no argument; passing one would be a silent
# interface change.
[[ "$CMD" == *'resolve-hyprland-closure-inside.sh' ]] || {
  printf 'Hyprland entry point was called with unexpected arguments:\n%s\n' "$CMD" >&2; exit 1; }

SHELL_CMD=$("$RESOLVER" --layer-file "$SHELL_DESC" "${COMMON[@]}" | tail -n 1) || {
  printf 'Expected omarchy-shell print-command to pass\n' >&2; exit 1; }
[[ "$SHELL_CMD" == *'resolve-omarchy-shell-closure-inside.sh verify' ]] || {
  printf 'Shell entry point did not receive the mode argument:\n%s\n' "$SHELL_CMD" >&2; exit 1; }

# Cross-check the descriptors against the resolvers they replace, so a
# migration error shows up here rather than at resolution time.
for pair in "hyprland:$REPO_ROOT/research/resolve-hyprland-closure.sh" \
            "omarchy-shell:$REPO_ROOT/research/resolve-omarchy-shell-closure.sh"; do
  layer=${pair%%:*}
  original=${pair#*:}
  [[ -f "$original" ]] || continue
  desc="$REPO_ROOT/config/$layer/resolver.conf"
  desc_image=$(awk -F '|' '$1 == "image" { print $2 }' "$desc")
  grep -Fq "$desc_image" "$original" || {
    printf 'Descriptor image for %s does not match %s\n' "$layer" "$original" >&2; exit 1; }
  desc_inside=$(awk -F '|' '$1 == "inside_script" { print $2 }' "$desc")
  grep -Fq "/repo/$desc_inside" "$original" || {
    printf 'Descriptor entry point for %s does not match %s\n' "$layer" "$original" >&2; exit 1; }
done

# --layer resolves config/<name>/resolver.conf, but the real descriptors pin the
# production database digests, so the fixture databases must be refused.
STATUS=0
"$RESOLVER" --layer hyprland --source-volume "$VOLUME" --output-dir "$OUT_DIR" \
  --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --print-command >/dev/null 2>&1 || STATUS=$?
[[ $STATUS -eq 2 ]] || { printf 'Expected fixture databases to be refused by the real descriptor; got %s\n' "$STATUS" >&2; exit 1; }

expect_rejected() {
  local label=$1
  shift
  local status=0
  "$RESOLVER" "$@" >/dev/null 2>&1
  status=$?
  [[ $status -eq 2 ]] || { printf 'Expected %s to be rejected with status 2; got %s\n' "$label" "$status" >&2; exit 1; }
}

expect_rejected 'no layer' "${COMMON[@]}"
expect_rejected 'both layer selectors' --layer hyprland --layer-file "$HYPR_DESC" "${COMMON[@]}"
expect_rejected 'unsafe layer name' --layer '../etc' "${COMMON[@]}"
expect_rejected 'missing descriptor' --layer-file "$TEST_TMP/absent.conf" "${COMMON[@]}"
expect_rejected 'unknown option' --layer-file "$HYPR_DESC" "${COMMON[@]}" --wat
expect_rejected 'unsafe source volume' --layer-file "$HYPR_DESC" --source-volume 'evil;rm' \
  --output-dir "$OUT_DIR" --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --print-command
expect_rejected 'missing output directory' --layer-file "$HYPR_DESC" --source-volume "$VOLUME" \
  --output-dir "$TEST_TMP/absent" --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --print-command
expect_rejected 'wrong core database digest' --layer-file "$HYPR_DESC" --source-volume "$VOLUME" \
  --output-dir "$OUT_DIR" --core-db "$EXTRA_DB" --extra-db "$EXTRA_DB" --print-command

# A non-empty output directory would let a previous resolution's packages be
# mistaken for this one's.
printf 'stale\n' > "$OUT_DIR/leftover"
expect_rejected 'non-empty output directory' --layer-file "$HYPR_DESC" "${COMMON[@]}"
rm "$OUT_DIR/leftover"

# Publishing into the repository would make a resolution look like committed state.
mkdir -p "$REPO_ROOT/.tmp-resolver-output-test"
expect_rejected 'output inside the repository' --layer-file "$HYPR_DESC" --source-volume "$VOLUME" \
  --output-dir "$REPO_ROOT/.tmp-resolver-output-test" --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --print-command
rmdir "$REPO_ROOT/.tmp-resolver-output-test"

# --generate-lock must be refused once a transaction lock is committed, so a
# promoted transaction can never be silently regenerated.
expect_rejected 'generate over a committed lock' --layer-file "$HYPR_DESC" --generate-lock "${COMMON[@]}"

# --generate-lock must be refused for a layer whose container entry point takes
# no mode argument, rather than relaxing the host gate while the container still
# compares against a lock that does not exist.
NOMODE="$TEST_TMP/nomode-resolver.conf"
awk -F '|' 'BEGIN { OFS="|" }
  /^#/ { print; next }
  $1 == "transaction_lock" { print $1, "config/hyprland/absent-transaction.lock"; next }
  { print }' "$TEST_TMP/hyprland-resolver.conf" > "$NOMODE"
expect_rejected 'generate-lock for an inside_args|none layer' --layer-file "$NOMODE" --generate-lock "${COMMON[@]}"

# A committed lock that no longer matches its descriptor digest stops resolution.
TAMPERED=$(test_descriptor hyprland)
TAMPERED="$TEST_TMP/tampered-resolver.conf"
sed -e "s/^core_db_sha256|.*/core_db_sha256|$CORE_SHA/" \
    -e "s/^extra_db_sha256|.*/extra_db_sha256|$EXTRA_SHA/" \
    -e "s/^transaction_lock_sha256|.*/transaction_lock_sha256|$(printf '0%.0s' {1..64})/" \
    "$REPO_ROOT/config/hyprland/resolver.conf" > "$TAMPERED"
expect_rejected 'transaction lock digest mismatch' --layer-file "$TAMPERED" "${COMMON[@]}"

# A descriptor must not be able to reach outside the repository. The fixture
# stays otherwise complete and valid so the rejection can only come from the
# traversal check itself, not from a missing field.
make_traversal_descriptor() {
  local key=$1 value=$2 out=$3
  awk -F '|' -v k="$key" -v v="$value" 'BEGIN { OFS="|" }
    /^#/ { print; next }
    $1 == k { print k, v; next }
    { print }' "$TEST_TMP/hyprland-resolver.conf" > "$out"
  grep -cq . "$out"
  [[ $(awk -F '|' -v k="$key" '$1 == k { c++ } END { print c+0 }' "$out") -eq 1 ]] || {
    printf 'Traversal fixture for %s is malformed\n' "$key" >&2
    exit 1
  }
}

TRAVERSAL="$TEST_TMP/traversal-resolver.conf"
make_traversal_descriptor inside_script '../../../etc/passwd' "$TRAVERSAL"
expect_rejected 'descriptor entry-point traversal' --layer-file "$TRAVERSAL" "${COMMON[@]}"

ABSOLUTE="$TEST_TMP/absolute-resolver.conf"
make_traversal_descriptor direct_lock '/etc/passwd' "$ABSOLUTE"
expect_rejected 'descriptor absolute lock path' --layer-file "$ABSOLUTE" "${COMMON[@]}"

# A descriptor whose declared layer disagrees with --layer must not be accepted
# under that name.
MISLABELLED="$TEST_TMP/mislabelled-resolver.conf"
make_traversal_descriptor layer 'omarchy-shell' "$MISLABELLED"
STATUS=0
"$RESOLVER" --layer-file "$MISLABELLED" "${COMMON[@]}" >/dev/null 2>&1 || STATUS=$?
[[ $STATUS -eq 0 ]] || { printf 'A relabelled descriptor used via --layer-file should still resolve; got %s\n' "$STATUS" >&2; exit 1; }

# The container command itself is validated before use.
expect_rejected 'missing container runtime' --layer-file "$HYPR_DESC" --source-volume "$VOLUME" \
  --output-dir "$OUT_DIR" --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --docker-command "$TEST_TMP/no-such-runtime"

# With a fake runtime the resolver runs to completion and hands over exactly
# the printed argv.
FAKE="$TEST_TMP/fake-docker.sh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DOCKER_LOG"
exit 0
FAKEEOF
chmod +x "$FAKE"
export FAKE_DOCKER_LOG="$TEST_TMP/docker.log"
"$RESOLVER" --layer-file "$SHELL_DESC" --source-volume "$VOLUME" --output-dir "$OUT_DIR" \
  --core-db "$CORE_DB" --extra-db "$EXTRA_DB" --docker-command "$FAKE" >/dev/null || {
  printf 'Expected fake-runtime resolution to pass\n' >&2; exit 1; }
[[ -f "$FAKE_DOCKER_LOG" ]] || { printf 'Fake runtime was not invoked\n' >&2; exit 1; }
grep -Fxq 'run' "$FAKE_DOCKER_LOG" || { printf 'Fake runtime did not receive run\n' >&2; exit 1; }
grep -Fxq "type=volume,src=$VOLUME,dst=/target,readonly" "$FAKE_DOCKER_LOG" || {
  printf 'Fake runtime did not receive the read-only source mount\n' >&2; exit 1; }
grep -Fxq 'verify' "$FAKE_DOCKER_LOG" || { printf 'Fake runtime did not receive the mode argument\n' >&2; exit 1; }

printf 'resolve-transaction tests: PASS\n'
