#!/usr/bin/env bash

# Test-only chown-compatible helper for synthetic roots owned by the invoking
# host user. Production scripts default to the real chown command.
set -u

# Accept both the recursive form used by the user seed and the single-path form
# used by the session handoff:
#   fake-chown.sh -R UID:GID PATH [PATH...]
#   fake-chown.sh    UID:GID PATH [PATH...]
if [[ ${1:-} == '-R' ]]; then
  [[ ${2:-} =~ ^[0-9]+:[0-9]+$ && $# -ge 4 ]] || exit 2
else
  [[ ${1:-} =~ ^[0-9]+:[0-9]+$ && $# -ge 2 ]] || exit 2
fi
exit 0
