#!/usr/bin/env bash

# Secret-safe host boundary for planning or applying real operator
# configuration to the retained Phase 1 root. Secret content is accepted only
# through private files mounted read-only at fixed container paths.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'Unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'Unable to resolve repository root\n' >&2; exit 2; fi

ACTION=plan
ACTION_SET=0
VOLUME=''
CONFIRM_VOLUME=''
ADMIN_USER=''
SSH_PUBLIC_KEY=''
CONSOLE_PASSWORD_HASH_FILE=''
WIFI_KEYFILE=''
REG_DOMAIN=''
HOSTNAME=uconsole
TIMEZONE=UTC
IMAGE='menci/archlinuxarm:base-devel-20260819.32222611223@sha256:26022929f3689861d451aebce558f3a7715a661ff669ca67589d36ae677299d0'

usage() {
  printf '%s\n' \
    'Usage: research/configure-phase1-operator-root.sh --volume V \' \
    '  --admin-user USER --ssh-public-key FILE \' \
    '  --console-password-hash-file FILE --reg-domain CC [options]' \
    '' \
    'Actions:' \
    '  --plan                   Validate with the root mounted read-only (default)' \
    '  --apply                  Apply, reapply idempotently, then inspect read-only' \
    '' \
    'Options:' \
    '  --confirm-volume V       Required with --apply; must exactly repeat --volume' \
    '  --wifi-keyfile FILE      Optional private NetworkManager WPA-PSK keyfile' \
    '  --hostname NAME          Hostname (default: uconsole)' \
    '  --timezone ZONE          IANA timezone (default: UTC)' \
    '  --help                   Show this help' \
    '' \
    'Never pass a plaintext password, private SSH key or Wi-Fi PSK as a value.' \
    'Private input files must be outside this repository and deny group/other access.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

set_action() {
  local requested=$1
  [[ $ACTION_SET -eq 0 ]] || die 'choose exactly one action'
  ACTION=$requested
  ACTION_SET=1
}

while (($# > 0)); do
  case "$1" in
    --plan) set_action plan; shift ;;
    --apply) set_action apply; shift ;;
    --volume) (($# >= 2)) || die '--volume requires a name'; VOLUME=$2; shift 2 ;;
    --confirm-volume) (($# >= 2)) || die '--confirm-volume requires a name'; CONFIRM_VOLUME=$2; shift 2 ;;
    --admin-user) (($# >= 2)) || die '--admin-user requires a value'; ADMIN_USER=$2; shift 2 ;;
    --ssh-public-key) (($# >= 2)) || die '--ssh-public-key requires a file'; SSH_PUBLIC_KEY=$2; shift 2 ;;
    --console-password-hash-file) (($# >= 2)) || die '--console-password-hash-file requires a file'; CONSOLE_PASSWORD_HASH_FILE=$2; shift 2 ;;
    --wifi-keyfile) (($# >= 2)) || die '--wifi-keyfile requires a file'; WIFI_KEYFILE=$2; shift 2 ;;
    --reg-domain) (($# >= 2)) || die '--reg-domain requires a value'; REG_DOMAIN=$2; shift 2 ;;
    --hostname) (($# >= 2)) || die '--hostname requires a value'; HOSTNAME=$2; shift 2 ;;
    --timezone) (($# >= 2)) || die '--timezone requires a value'; TIMEZONE=$2; shift 2 ;;
    --password|--password-hash|--wifi-password|--wifi-psk|--private-key)
      die "$1 is forbidden; use the documented private-file inputs"
      ;;
    --device|--write-device|--build-image|--publish)
      die "$1 is outside the operator-configuration boundary"
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$VOLUME" =~ ^uconsole-phase1-operator-pending-[0-9]{8}$ ]] || die 'volume must use uconsole-phase1-operator-pending-YYYYMMDD'
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || die 'admin user is missing or unsafe'
[[ "$REG_DOMAIN" =~ ^[A-Za-z]{2}$ ]] || die 'regulatory domain must be two letters'
[[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'hostname is unsafe'
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || die 'timezone is unsafe'
if [[ "$ACTION" == apply ]]; then
  [[ "$CONFIRM_VOLUME" == "$VOLUME" ]] || die '--apply requires --confirm-volume with the exact target volume name'
elif [[ -n "$CONFIRM_VOLUME" ]]; then
  die '--confirm-volume is accepted only with --apply'
fi

resolve_input_file() {
  local label=$1
  local file_name=$2
  [[ -f "$file_name" && ! -L "$file_name" ]] || die "$label is missing, not regular or a symlink"
  [[ "$file_name" != *$'\n'* && "$file_name" != *,* ]] || die "$label path contains a forbidden character"
  local parent=${file_name%/*}
  local base=${file_name##*/}
  [[ "$parent" != "$file_name" ]] || parent=.
  parent=$(cd -- "$parent" && pwd -P) || die "unable to resolve $label parent"
  printf '%s/%s\n' "$parent" "$base"
}

SSH_PUBLIC_KEY=$(resolve_input_file 'SSH public key' "$SSH_PUBLIC_KEY")
CONSOLE_PASSWORD_HASH_FILE=$(resolve_input_file 'console password hash' "$CONSOLE_PASSWORD_HASH_FILE")
case "$CONSOLE_PASSWORD_HASH_FILE" in "$REPO_ROOT"/*) die 'console password hash must be outside the repository' ;; esac
if [[ -n "$WIFI_KEYFILE" ]]; then
  WIFI_KEYFILE=$(resolve_input_file 'Wi-Fi keyfile' "$WIFI_KEYFILE")
  case "$WIFI_KEYFILE" in "$REPO_ROOT"/*) die 'Wi-Fi keyfile must be outside the repository' ;; esac
fi

command -v docker >/dev/null 2>&1 || die 'docker is required'
docker volume inspect "$VOLUME" >/dev/null || die "Docker volume does not exist: $VOLUME"
CONTAINER_REFERENCES=$(docker ps -aq --filter "volume=$VOLUME") || die 'unable to inspect volume references'
[[ -z "$CONTAINER_REFERENCES" ]] || die 'target volume is referenced by a container'

VOLUME_MOUNT="type=volume,src=$VOLUME,dst=/output"
if [[ "$ACTION" == plan ]]; then VOLUME_MOUNT="$VOLUME_MOUNT,readonly"; fi
DOCKER_ARGS=(
  run --rm --read-only --log-driver none --privileged --platform linux/arm64 --network none
  --tmpfs /run:rw,nosuid,nodev
  --env "UCONSOLE_CONFIG_ACTION=$ACTION"
  --env "UCONSOLE_ADMIN_USER=$ADMIN_USER"
  --env "UCONSOLE_REG_DOMAIN=$REG_DOMAIN"
  --env "UCONSOLE_HOSTNAME=$HOSTNAME"
  --env "UCONSOLE_TIMEZONE=$TIMEZONE"
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly"
  --mount "$VOLUME_MOUNT"
  --mount "type=bind,src=$SSH_PUBLIC_KEY,dst=/run/uconsole-operator-ssh-public-key,readonly"
  --mount "type=bind,src=$CONSOLE_PASSWORD_HASH_FILE,dst=/run/uconsole-operator-console-password-hash,readonly"
)
if [[ -n "$WIFI_KEYFILE" ]]; then
  DOCKER_ARGS+=(--env UCONSOLE_WIFI_PRESEED=yes)
  DOCKER_ARGS+=(--mount "type=bind,src=$WIFI_KEYFILE,dst=/run/uconsole-operator-wifi-keyfile,readonly")
else
  DOCKER_ARGS+=(--env UCONSOLE_WIFI_PRESEED=no)
fi
DOCKER_ARGS+=("$IMAGE" /repo/research/container/configure-phase1-operator-root-inside.sh)

docker "${DOCKER_ARGS[@]}" || exit $?
if [[ "$ACTION" == apply ]]; then
  "$SCRIPT_DIR/inspect-phase1-configured-root.sh" --volume "$VOLUME"
fi
