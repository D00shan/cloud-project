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

validate_json_file() {
  local json_file="$1"

  [[ -f "$json_file" ]] \
    || die "Required generated JSON file is missing: $json_file"

  jq empty "$json_file" >/dev/null 2>&1 \
    || die "Generated file is not valid JSON: $json_file"

  if grep -Eq '\$\{[^}]+\}' "$json_file"; then
    die "Generated JSON contains an unresolved placeholder: $json_file"
  fi

  if grep -Eqi \
    '555751475057|cloud-project-file-sharing-bucket|file-compression-queue|FileCompressionHandler|AWSLambdaBasicExecutionRole-[A-Za-z0-9-]+' \
    "$json_file"; then

    die "Generated JSON contains a known historical identifier: $json_file"
  fi
}

validate_generated_json_directory() {
  local generated_directory="$1"
  shift
  local required_file
  local generated_file
  local generated_file_count=0

  [[ -d "$generated_directory" ]] \
    || die "Generated JSON directory is missing: $generated_directory"

  for required_file in "$@"; do
    validate_json_file "$generated_directory/$required_file"
  done

  while IFS= read -r -d '' generated_file; do
    validate_json_file "$generated_file"
    generated_file_count=$((generated_file_count + 1))
  done < <(find "$generated_directory" -maxdepth 1 -type f -name '*.json' -print0)

  (( generated_file_count > 0 )) \
    || die "No generated JSON files were found in: $generated_directory"
}
