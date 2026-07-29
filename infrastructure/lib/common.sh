#!/usr/bin/env bash

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 \
    || die "Required command not found: $command_name"
}

require_config_value() {
  local variable_name="$1"

  [[ -n "${!variable_name:-}" ]] \
    || die "Required config value is missing: $variable_name"
}

require_integer_between() {
  local variable_name="$1"
  local minimum="$2"
  local maximum="$3"
  local value="${!variable_name:-}"

  [[ "$value" =~ ^[0-9]+$ ]] \
    || die "$variable_name must be an integer; got: ${value:-<empty>}"

  (( value >= minimum && value <= maximum )) \
    || die "$variable_name must be between $minimum and $maximum; got: $value"
}