#!/usr/bin/env bash

# Shared safety helpers for offline-root installers. This file does not set
# shell options because each entry-point must do that before sourcing it.

install_common_die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

install_common_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

install_common_sha256() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    return 127
  fi
}

install_common_require_file() {
  local label=$1
  local path=$2
  [[ -f "$path" ]] || install_common_die "$label is not a regular file: $path"
  [[ ! -L "$path" ]] || install_common_die "$label must not be a symbolic link: $path"
}

install_common_require_offline_arch_root() {
  local root=$1
  local canonical=""
  local os_release=""

  [[ -n "$root" ]] || install_common_die '--root is required'
  [[ -d "$root" ]] || install_common_die "root is not a directory: $root"
  [[ ! -L "$root" ]] || install_common_die "root must not be a symbolic link: $root"
  canonical=$(cd -- "$root" && pwd -P) || install_common_die "unable to resolve root: $root"
  [[ "$canonical" != '/' ]] || install_common_die 'the live root is forbidden; mount a development image root instead'
  case "$canonical" in
    /dev|/dev/*) install_common_die "paths below /dev are forbidden: $canonical" ;;
  esac

  os_release="$canonical/etc/os-release"
  [[ -f "$os_release" ]] || install_common_die "missing Arch Linux ARM identity: $os_release"
  if ! grep -Eq '^ID=(archarm|arch)$|^NAME="?Arch Linux ARM"?$' "$os_release"; then
    install_common_die "offline root does not identify as Arch Linux ARM: $canonical"
  fi
  [[ -d "$canonical/boot" ]] || install_common_die "offline root has no boot directory: $canonical/boot"
  [[ -d "$canonical/var/lib/pacman/local" ]] || install_common_die "offline root has no pacman database: $canonical/var/lib/pacman/local"

  printf '%s\n' "$canonical"
}

install_common_package_field() {
  local package=$1
  local field=$2
  local pkginfo=""
  pkginfo=$(bsdtar -xOf "$package" .PKGINFO 2>/dev/null) || return 1
  printf '%s\n' "$pkginfo" | awk -F ' = ' -v wanted="$field" '$1 == wanted { print $2; exit }'
}

install_common_assert_package_arch() {
  local package=$1
  local expected_name=$2
  local expected_version=$3
  local expected_arch=$4
  local expected_sha=$5
  local observed_name=""
  local observed_version=""
  local observed_arch=""
  local observed_sha=""

  install_common_require_file package "$package"
  command -v bsdtar >/dev/null 2>&1 || install_common_die 'bsdtar is required to inspect package metadata'

  observed_name=$(install_common_package_field "$package" pkgname) || install_common_die "cannot read .PKGINFO: $package"
  observed_version=$(install_common_package_field "$package" pkgver) || install_common_die "cannot read package version: $package"
  observed_arch=$(install_common_package_field "$package" arch) || install_common_die "cannot read package architecture: $package"
  [[ "$observed_name" == "$expected_name" ]] || install_common_die "expected package $expected_name; observed ${observed_name:-unknown}"
  [[ "$observed_version" == "$expected_version" ]] || install_common_die "expected $expected_name version $expected_version; observed ${observed_version:-unknown}"
  [[ "$observed_arch" == "$expected_arch" ]] || install_common_die "expected $expected_arch package; observed ${observed_arch:-unknown} for $expected_name"

  observed_sha=$(install_common_sha256 "$package") || install_common_die 'neither sha256sum nor shasum is available'
  [[ "$observed_sha" == "$expected_sha" ]] || install_common_die "SHA-256 mismatch for $expected_name: $observed_sha"
  printf '[PASS] %-24s %s %s sha256=%s\n' "$expected_name" "$observed_version" "$observed_arch" "$observed_sha"
}

install_common_assert_package() {
  install_common_assert_package_arch "$1" "$2" "$3" aarch64 "$4"
}
