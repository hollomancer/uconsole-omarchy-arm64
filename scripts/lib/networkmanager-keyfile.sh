#!/usr/bin/env bash

# GLib keyfile string escaping used for NetworkManager string properties.
# Callers must separately reject embedded newline, tab and carriage return.

uconsole_nm_keyfile_escape() {
  local value=$1
  local leading=''
  local trailing=''
  while [[ "$value" == ' '* ]]; do leading="${leading}\\s"; value=${value# }; done
  while [[ -n "$value" && "$value" == *' ' ]]; do trailing="\\s${trailing}"; value=${value% }; done
  value=${value//\\/\\\\}
  printf '%s%s%s' "$leading" "$value" "$trailing"
}
