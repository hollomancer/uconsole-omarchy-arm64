#!/usr/bin/env bash

# Test-only chown-compatible helper for synthetic roots owned by the invoking
# host user. Production scripts default to the real chown command.
set -u
[[ ${1:-} == '-R' && ${2:-} =~ ^[0-9]+:[0-9]+$ && $# -ge 4 ]] || exit 2
exit 0
