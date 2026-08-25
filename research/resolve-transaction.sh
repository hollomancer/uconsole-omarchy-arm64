#!/usr/bin/env bash

# One transaction resolver for every package layer.
#
# research/resolve-hyprland-closure.sh and research/resolve-omarchy-shell-closure.sh
# were about ninety percent identical, differing only in which lock files they
# read, which container entry point they ran, and whether a first resolution was
# permitted. Phase 6 needs the same operation again for every promoted update,
# so the differences move into a per-layer descriptor and the safety envelope is
# written once.
#
#   research/resolve-transaction.sh --layer hyprland \
#     --source-volume uconsole-... --output-dir /new/empty/dir
#
# A layer is described by config/<layer>/resolver.conf. --layer-file accepts a
# descriptor path directly, which is how the tests exercise this without the
# frozen production databases.
#
# The source volume is mounted read-only, the output directory must be new and
# empty, and packages are published only after the whole transaction resolves
# and passes signature verification. Nothing is installed and no mirror is
# contacted: resolution runs against frozen, content-pinned databases.
#
# --docker-command is a test hook. Production uses docker.

set -u
set -o pipefail

SCRIPT_DIR=''
if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); then printf 'ERROR: unable to resolve research directory\n' >&2; exit 2; fi
REPO_ROOT=''
if ! REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd); then printf 'ERROR: unable to resolve repository root\n' >&2; exit 2; fi

LAYER=''
LAYER_FILE=''
SOURCE_VOLUME=''
OUTPUT_DIR=''
MODE='verify'
CORE_DB=/private/tmp/uconsole-image-core.db
EXTRA_DB=/private/tmp/uconsole-image-extra.db
DOCKER_COMMAND='docker'

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

usage() {
  printf '%s\n' \
    'Usage: research/resolve-transaction.sh --layer NAME --source-volume V --output-dir NEW_EMPTY_DIR [options]' \
    '' \
    'Options:' \
    '  --layer NAME       Layer described by config/NAME/resolver.conf' \
    '  --layer-file FILE  Use this descriptor directly instead of --layer' \
    '  --generate-lock    Permit the first resolution when no transaction lock exists' \
    '  --core-db FILE     Frozen Arch Linux ARM core database' \
    '  --extra-db FILE    Frozen Arch Linux ARM extra database' \
    '  --print-command    Print the resolved container command and exit' \
    '  --docker-command C Container runtime (test hook; production uses docker)' \
    '  --help             Show this help' \
    '' \
    'Resolution runs against frozen databases only. No mirror is contacted and' \
    'no package is installed.'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 127
  fi
}

PRINT_ONLY=0
while (($# > 0)); do
  case "$1" in
    --layer) (($# >= 2)) || die '--layer requires a name'; LAYER=$2; shift 2 ;;
    --layer-file) (($# >= 2)) || die '--layer-file requires a file'; LAYER_FILE=$2; shift 2 ;;
    --source-volume) (($# >= 2)) || die '--source-volume requires a name'; SOURCE_VOLUME=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || die '--output-dir requires a directory'; OUTPUT_DIR=$2; shift 2 ;;
    --generate-lock) MODE='generate'; shift ;;
    --core-db) (($# >= 2)) || die '--core-db requires a file'; CORE_DB=$2; shift 2 ;;
    --extra-db) (($# >= 2)) || die '--extra-db requires a file'; EXTRA_DB=$2; shift 2 ;;
    --print-command) PRINT_ONLY=1; shift ;;
    --docker-command) (($# >= 2)) || die '--docker-command requires a command'; DOCKER_COMMAND=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Resolve the descriptor.
if [[ -n "$LAYER" && -n "$LAYER_FILE" ]]; then die 'choose either --layer or --layer-file, not both'; fi
if [[ -n "$LAYER" ]]; then
  [[ "$LAYER" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "unsafe layer name: $LAYER"
  LAYER_FILE="$REPO_ROOT/config/$LAYER/resolver.conf"
fi
[[ -n "$LAYER_FILE" ]] || die 'choose --layer or --layer-file'
[[ -f "$LAYER_FILE" && ! -L "$LAYER_FILE" ]] || die "layer descriptor is missing or unsafe: $LAYER_FILE"

descriptor_field() {
  local key=$1
  awk -F '|' -v wanted="$key" '$0 !~ /^#/ && $1 == wanted { count++; value=$2 } END { if (count == 1 && value != "") print value; else exit 1 }' "$LAYER_FILE"
}

D_LAYER=$(descriptor_field layer) || die 'descriptor lacks exactly one layer'
D_DESCRIPTION=$(descriptor_field description) || die 'descriptor lacks exactly one description'
D_DIRECT_LOCK=$(descriptor_field direct_lock) || die 'descriptor lacks exactly one direct_lock'
D_DIRECT_SHA=$(descriptor_field direct_lock_sha256) || die 'descriptor lacks exactly one direct_lock_sha256'
D_TRANSACTION_LOCK=$(descriptor_field transaction_lock) || die 'descriptor lacks exactly one transaction_lock'
D_TRANSACTION_SHA=$(descriptor_field transaction_lock_sha256) || die 'descriptor lacks exactly one transaction_lock_sha256'
D_INSIDE=$(descriptor_field inside_script) || die 'descriptor lacks exactly one inside_script'
D_INSIDE_ARGS=$(descriptor_field inside_args) || die 'descriptor lacks exactly one inside_args'
D_CORE_SHA=$(descriptor_field core_db_sha256) || die 'descriptor lacks exactly one core_db_sha256'
D_EXTRA_SHA=$(descriptor_field extra_db_sha256) || die 'descriptor lacks exactly one extra_db_sha256'
D_IMAGE=$(descriptor_field image) || die 'descriptor lacks exactly one image'
D_TMPFS=$(descriptor_field tmpfs_size_mb) || die 'descriptor lacks exactly one tmpfs_size_mb'

[[ "$D_LAYER" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "descriptor declares an unsafe layer name: $D_LAYER"
[[ "$D_DIRECT_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'descriptor direct_lock_sha256 is malformed'
[[ "$D_TRANSACTION_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'descriptor transaction_lock_sha256 is malformed'
[[ "$D_CORE_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'descriptor core_db_sha256 is malformed'
[[ "$D_EXTRA_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'descriptor extra_db_sha256 is malformed'
[[ "$D_TMPFS" =~ ^[0-9]+$ ]] || die 'descriptor tmpfs_size_mb is malformed'
[[ "$D_INSIDE_ARGS" == 'none' || "$D_INSIDE_ARGS" == 'mode' ]] || die 'descriptor inside_args must be none or mode'
[[ -n "$LAYER" && "$D_LAYER" != "$LAYER" ]] && die "descriptor layer '$D_LAYER' does not match requested layer '$LAYER'"

# Descriptor paths are repository-relative by contract; an absolute or
# traversing path would let a descriptor reach outside the repository.
for relative in "$D_DIRECT_LOCK" "$D_TRANSACTION_LOCK" "$D_INSIDE"; do
  case "$relative" in
    /*|*..*) die "descriptor path must be repository-relative without traversal: $relative" ;;
  esac
done

DIRECT_LOCK="$REPO_ROOT/$D_DIRECT_LOCK"
TRANSACTION_LOCK="$REPO_ROOT/$D_TRANSACTION_LOCK"
INSIDE_SCRIPT="$REPO_ROOT/$D_INSIDE"

[[ -f "$DIRECT_LOCK" && ! -L "$DIRECT_LOCK" ]] || die "direct package lock is missing or unsafe: $DIRECT_LOCK"
[[ $(sha256_file "$DIRECT_LOCK") == "$D_DIRECT_SHA" ]] || die 'direct package lock SHA-256 mismatch'
[[ -f "$INSIDE_SCRIPT" && ! -L "$INSIDE_SCRIPT" ]] || die "container entry point is missing or unsafe: $INSIDE_SCRIPT"

# A committed transaction lock is the norm. --generate-lock exists only for the
# reviewed first resolution of a new layer and is refused once a lock exists,
# so a promoted transaction can never be silently regenerated.
if [[ "$MODE" == 'generate' ]]; then
  # The mode only reaches the container for descriptors that declare
  # inside_args|mode. Allowing --generate-lock for an inside_args|none layer
  # would relax the host gate while the container still ran its unconditional
  # comparison against a lock that does not exist yet, so refuse it here
  # instead of failing confusingly inside the container.
  [[ "$D_INSIDE_ARGS" == 'mode' ]] || die "layer '$D_LAYER' declares inside_args|none and cannot accept --generate-lock; its container entry point takes no mode argument"
  [[ ! -e "$TRANSACTION_LOCK" ]] || die '--generate-lock is forbidden once a transaction lock is committed'
else
  [[ -f "$TRANSACTION_LOCK" && ! -L "$TRANSACTION_LOCK" ]] || die 'committed transaction lock is required; use --generate-lock only for the reviewed first resolution'
  [[ $(sha256_file "$TRANSACTION_LOCK") == "$D_TRANSACTION_SHA" ]] || die 'committed transaction lock SHA-256 mismatch'
fi

[[ "$SOURCE_VOLUME" =~ ^uconsole-[a-z0-9][a-z0-9._-]*$ ]] || die 'unsafe or missing uConsole source volume'
[[ -n "$OUTPUT_DIR" ]] || die '--output-dir is required'
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die 'output must be an existing real directory'
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P) || die 'cannot resolve output directory'
[[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'output directory must be empty'
case "$OUTPUT_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) die 'output directory must not be inside the repository' ;;
esac

for database in "$CORE_DB" "$EXTRA_DB"; do
  [[ -f "$database" && ! -L "$database" ]] || die "frozen database is missing or unsafe: $database"
done
[[ $(sha256_file "$CORE_DB") == "$D_CORE_SHA" ]] || die 'frozen core database SHA-256 mismatch'
[[ $(sha256_file "$EXTRA_DB") == "$D_EXTRA_SHA" ]] || die 'frozen extra database SHA-256 mismatch'
CORE_DB=$(cd -- "$(dirname -- "$CORE_DB")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$CORE_DB")") || die 'cannot resolve core database path'
EXTRA_DB=$(cd -- "$(dirname -- "$EXTRA_DB")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$EXTRA_DB")") || die 'cannot resolve extra database path'

CONTAINER_ARGS=(
  run --rm --platform linux/arm64
  --mount "type=bind,src=$REPO_ROOT,dst=/repo,readonly"
  --mount "type=bind,src=$CORE_DB,dst=/snapshot/core.db,readonly"
  --mount "type=bind,src=$EXTRA_DB,dst=/snapshot/extra.db,readonly"
  --mount "type=bind,src=$OUTPUT_DIR,dst=/output"
  --mount "type=volume,src=$SOURCE_VOLUME,dst=/target,readonly"
  --tmpfs "/work:rw,size=${D_TMPFS}m"
  "$D_IMAGE"
  "/repo/$D_INSIDE"
)
[[ "$D_INSIDE_ARGS" != 'mode' ]] || CONTAINER_ARGS+=("$MODE")

printf '%s\n' \
  "[PASS] layer                 $D_LAYER — $D_DESCRIPTION" \
  "[PASS] direct lock           $D_DIRECT_LOCK sha256=$D_DIRECT_SHA" \
  "[PASS] transaction lock      $D_TRANSACTION_LOCK mode=$MODE" \
  "[PASS] frozen databases      core and extra match the pinned snapshot" \
  "[PASS] source volume         $SOURCE_VOLUME (read-only)" \
  "[PASS] output directory      $OUTPUT_DIR (new and empty)"

if [[ $PRINT_ONLY -eq 1 ]]; then
  printf '%s' "$DOCKER_COMMAND"
  printf ' %s' "${CONTAINER_ARGS[@]}"
  printf '\n'
  exit 0
fi

if [[ "$DOCKER_COMMAND" == */* ]]; then
  [[ -x "$DOCKER_COMMAND" ]] || die "container command is not executable: $DOCKER_COMMAND"
else
  command -v "$DOCKER_COMMAND" >/dev/null 2>&1 || die "container command not found: $DOCKER_COMMAND"
fi
if [[ "$DOCKER_COMMAND" == 'docker' ]]; then
  docker volume inspect "$SOURCE_VOLUME" >/dev/null || die "Docker volume does not exist: $SOURCE_VOLUME"
fi

exec "$DOCKER_COMMAND" "${CONTAINER_ARGS[@]}"
