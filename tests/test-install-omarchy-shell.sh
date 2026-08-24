#!/usr/bin/env bash

# Fast contract checks for the exact offline shell installer. The native ARM64
# apply is covered separately by the retained integration evidence.

set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd) || exit 2
INSTALLER="$REPO_ROOT/scripts/install-omarchy-shell.sh"
DIRECT_LOCK="$REPO_ROOT/config/omarchy-shell/packages.lock"
TRANSACTION_LOCK="$REPO_ROOT/config/omarchy-shell/transaction.lock"
USERLAND_LOCK="$REPO_ROOT/config/omarchy-shell/userland.lock"
RUNTIME_POLICY="$REPO_ROOT/config/arm64-overrides/omarchy-runtime-command-policy.tsv"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

bash -n "$INSTALLER"
[[ $(sha256_file "$DIRECT_LOCK") == 019a79e470a26a7b3c34adb5209f02269eca3cb4df78e70a15aa41619f097159 ]]
[[ $(sha256_file "$TRANSACTION_LOCK") == 9cdf7f52c8f5da8a857ebd1fd3c90a7e299965396b9a2ca4fb0116f633a546e3 ]]
[[ $(sha256_file "$USERLAND_LOCK") == 837b81b7c29e83b09cce5da831d4907691cf93d98c0be2b16d8f77be55529008 ]]
[[ $(sha256_file "$RUNTIME_POLICY") == 5c5c8e3e01b4217294210a1442af8c3b42d42f4f1b97f29cec85ded8296c724d ]]

[[ $(awk -F '|' '$0 !~ /^#/ && NF {n++} END {print n+0}' "$DIRECT_LOCK") -eq 10 ]]
[[ $(awk -F '|' '$0 !~ /^#/ && NF {n++} END {print n+0}' "$TRANSACTION_LOCK") -eq 24 ]]
[[ $(awk -F '|' '$0 !~ /^#/ && NF {n++} END {print n+0}' "$USERLAND_LOCK") -eq 1 ]]
[[ $(awk -F '|' '$0 !~ /^#/ && NF {n++} END {print n+0}' "$RUNTIME_POLICY") -eq 54 ]]
[[ $(awk -F '|' '$0 !~ /^#/ && $3 != "inactive-optional" {n++} END {print n+0}' "$RUNTIME_POLICY") -eq 51 ]]

if awk -F '|' '$0 !~ /^#/ && $1 ~ /^(linux|linux-|linux-rpi|linux-firmware|raspberrypi-|uconsole-|mkinitcpio|limine|grub|uboot)/ {found=1} END {exit !found}' "$TRANSACTION_LOCK"; then
  printf 'Hardware or boot package entered the shell transaction\n' >&2
  exit 1
fi

HELP_OUTPUT=$($INSTALLER --help)
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'No mirror is contacted.'
printf '%s\n' "$HELP_OUTPUT" | grep -Fq 'No home, session, service enablement'

for forbidden in --activate --enable-uwsm --enable-display-manager --run-migrations --allow-live-root --device --write-device --force; do
  "$INSTALLER" "$forbidden" >/dev/null 2>&1
  [[ $? -eq 2 ]] || {
    printf 'Expected %s to be rejected\n' "$forbidden" >&2
    exit 1
  }
done

printf 'install Omarchy shell contract tests: PASS\n'
