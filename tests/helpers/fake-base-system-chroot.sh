#!/usr/bin/env bash

# Deterministic chroot stand-in for base-system configuration fixtures. Secret
# stdin is applied to the fixture shadow file and never written to the log.

set -u
set -o pipefail

ROOT=$1
shift
COMMAND=$1
shift
LOG=${FAKE_BASE_CHROOT_LOG:?}
PACKAGE_DATABASE="$ROOT/var/lib/fake-base-packages"
UNIT_STATE="$ROOT/var/lib/fake-systemctl"

printf '%s' "$COMMAND" >> "$LOG"
printf ' %s' "$@" >> "$LOG"
printf '\n' >> "$LOG"

rewrite_shadow() {
  local account=$1
  local replacement=$2
  local temporary="$ROOT/etc/.shadow.fake.$$"
  awk -F ':' -v OFS=':' -v wanted="$account" -v value="$replacement" '
    $1 == wanted { $2=value; found=1 }
    { print }
    END { if (!found) exit 1 }
  ' "$ROOT/etc/shadow" > "$temporary" || return 1
  mv "$temporary" "$ROOT/etc/shadow"
}

case "$COMMAND" in
  ssh-keygen)
    # Host-side ssh-keygen is used by ordinary fixtures. This branch supports
    # environments that deliberately validate an in-root public key.
    /usr/bin/ssh-keygen "$@"
    ;;
  pacman)
    [[ "$1" == -Q ]] || { printf 'Unexpected fake pacman operation: %s\n' "$1" >&2; exit 90; }
    awk -v wanted="$2" '$1 == wanted { print; found=1 } END { exit !found }' "$PACKAGE_DATABASE"
    ;;
  useradd)
    username=${!#}
    if awk -F ':' -v wanted="$username" '$1 == wanted { found=1 } END { exit !found }' "$ROOT/etc/passwd"; then exit 9; fi
    next_uid=1001
    printf '%s:x:%s:%s:Fixture Admin:/home/%s:/bin/bash\n' "$username" "$next_uid" "$next_uid" "$username" >> "$ROOT/etc/passwd"
    printf '%s:x:%s:\n' "$username" "$next_uid" >> "$ROOT/etc/group"
    printf '%s:!:20000:0:99999:7:::\n' "$username" >> "$ROOT/etc/shadow"
    mkdir -p "$ROOT/home/$username"
    ;;
  usermod)
    username=${!#}
    temporary="$ROOT/etc/.group.fake.$$"
    awk -F ':' -v OFS=':' -v user="$username" '
      $1 == "wheel" {
        if ($4 == "") $4=user
        else if ($4 !~ "(^|,)" user "(,|$)") $4=$4 "," user
      }
      { print }
    ' "$ROOT/etc/group" > "$temporary" || exit 1
    mv "$temporary" "$ROOT/etc/group"
    ;;
  chpasswd)
    IFS=':' read -r username password_hash
    [[ -n "$username" && -n "$password_hash" ]] || exit 1
    rewrite_shadow "$username" "$password_hash"
    ;;
  passwd)
    [[ "$1" == --lock ]] || exit 91
    username=$2
    current=$(awk -F ':' -v wanted="$username" '$1 == wanted { print $2; found=1 } END { exit !found }' "$ROOT/etc/shadow") || exit 1
    case "$current" in !*|\**) ;; *) rewrite_shadow "$username" "!$current" ;; esac
    ;;
  locale-gen)
    mkdir -p "$ROOT/usr/lib/locale"
    printf 'fixture locale archive\n' > "$ROOT/usr/lib/locale/locale-archive"
    ;;
  chown)
    [[ "$1" == -R && -n "$2" && "$3" == /home/*/.ssh ]] || exit 95
    ;;
  visudo)
    [[ "$1" == --check && "$2" == --file && -f "$ROOT$3" ]] || exit 92
    ;;
  systemctl)
    operation=$1
    shift
    mkdir -p "$UNIT_STATE"
    case "$operation" in
      enable)
        for unit in "$@"; do : > "$UNIT_STATE/$unit"; done
        ;;
      disable)
        for unit in "$@"; do rm -f -- "$UNIT_STATE/$unit"; done
        ;;
      is-enabled)
        if [[ -f "$UNIT_STATE/$1" ]]; then printf 'enabled\n'; exit 0; fi
        printf 'disabled\n'
        exit 1
        ;;
      *) printf 'Unexpected fake systemctl operation: %s\n' "$operation" >&2; exit 93 ;;
    esac
    ;;
  *)
    printf 'Unexpected fake base chroot command: %s %s\n' "$COMMAND" "$*" >&2
    exit 94
    ;;
esac
