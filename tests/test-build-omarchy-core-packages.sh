#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR=''
if ! TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then
  printf 'Unable to resolve test directory\n' >&2
  exit 2
fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd); then
  printf 'Unable to resolve repository root\n' >&2
  exit 2
fi

BUILDER="$REPO_ROOT/research/build-omarchy-core-packages.sh"
RUNNER="$REPO_ROOT/research/container/build-omarchy-core-packages-inside.sh"
RESOLVER="$REPO_ROOT/research/resolve-omarchy-core-build-closure.sh"
CONTAINER_RESOLVER="$REPO_ROOT/research/container/resolve-omarchy-core-build-closure-inside.sh"
LOCK="$REPO_ROOT/research/omarchy-core-build-transaction.lock"
INPUTS="$REPO_ROOT/research/omarchy-core-build-inputs.yaml"
RESULTS="$REPO_ROOT/research/omarchy-core-build-results.yaml"
POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-base-package-policy.tsv"
PATCH="$REPO_ROOT/packaging/omarchy-core/ttfx/aarch64-test-tolerance.patch"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

for script in "$BUILDER" "$RUNNER" "$RESOLVER" "$CONTAINER_RESOLVER"; do
  [[ -x "$script" && ! -L "$script" ]] || fail "missing, unsafe or non-executable script: $script"
  bash -n "$script" || fail "shell syntax failed: $script"
done
for package_name in omacalc omacut ttf-ia-writer ttfx yaru-icon-theme; do
  recipe="$REPO_ROOT/packaging/omarchy-core/$package_name/PKGBUILD"
  [[ -f "$recipe" && ! -L "$recipe" ]] || fail "missing or unsafe recipe: $package_name"
  bash -n "$recipe" || fail "recipe syntax failed: $package_name"
done

"$BUILDER" --help >/dev/null || fail 'builder help failed'
if "$BUILDER" --apply >/dev/null 2>&1; then
  fail 'builder accepted a target mutation option'
fi
if "$BUILDER" --source-dir /missing --dependency-dir /missing >/dev/null 2>&1; then
  fail 'builder accepted missing inputs'
fi

grep -Fq -- '--network none' "$BUILDER" || fail 'container network is not disabled'
if grep -E '^docker run ' "$BUILDER" | grep -Eq -- '--privileged|--device'; then
  fail 'builder requests device or privileged access'
fi
grep -Fq 'CARGO_NET_OFFLINE=true' "$RUNNER" || fail 'Cargo offline mode is absent'
grep -Fq -- '--wrap-mode=nodownload' "$REPO_ROOT/packaging/omarchy-core/yaru-icon-theme/PKGBUILD" || fail 'Yaru downloads are not disabled'
grep -Fq 'archive ownership is root:root' "$RUNNER" || fail 'archive ownership gate is absent'
grep -Fq 'unexpectedly contains GTK themes' "$RUNNER" || fail 'Yaru split-package gate is absent'

LOCK_ROWS=$(awk '$0 !~ /^#/ {count++} END {print count+0}' "$LOCK")
[[ $LOCK_ROWS -eq 171 ]] || fail "expected 171 locked dependencies; found $LOCK_ROWS"
LOCK_SHA=$(sha256_file "$LOCK") || fail 'SHA-256 utility unavailable'
[[ "$LOCK_SHA" == 6b87b553c129dbecc79c869b632528e458ca1edce9422bfea3c5442822261861 ]] || fail 'dependency lock hash differs'
PATCH_SHA=$(sha256_file "$PATCH") || fail 'unable to hash ttfx patch'
[[ "$PATCH_SHA" == 51625ca5cf349fb0573ea95a31607a68199905280cd672a0c2c8c95480e78c55 ]] || fail 'ttfx adaptation hash differs'
grep -Fq "'${PATCH_SHA}'" "$REPO_ROOT/packaging/omarchy-core/ttfx/PKGBUILD" || fail 'ttfx recipe does not pin its adaptation'
grep -Fq "sha256: $PATCH_SHA" "$INPUTS" || fail 'build manifest does not pin the ttfx adaptation'

[[ $(grep -c '^  - package:' "$RESULTS") -eq 5 ]] || fail 'result artifact count differs'
grep -Fq 'status: PASS_OFF_TARGET' "$RESULTS" || fail 'off-target result status is absent'
grep -Fq 'byte_identical_package_archives: 5' "$RESULTS" || fail 'reproducibility evidence is absent'
for package_name in omacalc omacut ttf-ia-writer ttfx yaru-icon-theme; do
  awk -F '|' -v package_name="$package_name" '
    $1 == package_name && $4 == "local-build" { found=1 }
    END { exit !found }
  ' "$POLICY" || fail "package policy lacks completed local build: $package_name"
done

printf 'Omarchy core package build tests: PASS (5 artifacts, 171 locked dependencies)\n'
