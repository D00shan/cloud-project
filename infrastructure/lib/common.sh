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

validate_account_id() {
  local account_id="$1"

  [[ "$account_id" =~ ^[0-9]{12}$ ]] \
    || die "AWS account ID must contain exactly 12 digits; got: ${account_id:-<empty>}"
}

validate_aws_partition() {
  local partition="$1"

  [[ "$partition" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "AWS partition has an invalid format: ${partition:-<empty>}"
}

validate_aws_region() {
  local region="$1"

  [[ "$region" =~ ^[a-z0-9]+(-[a-z0-9]+)+$ ]] \
    || die "AWS region has an invalid format: ${region:-<empty>}"
}

validate_bucket_name() {
  local bucket_name="$1"

  (( ${#bucket_name} >= 3 && ${#bucket_name} <= 63 )) \
    || die "Bucket name must be 3-63 characters; got ${#bucket_name}: $bucket_name"

  [[ "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] \
    || die "Bucket name contains invalid characters: $bucket_name"

  [[ "$bucket_name" != *..* ]] \
    || die "Bucket name cannot contain adjacent periods: $bucket_name"

  [[ ! "$bucket_name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "Bucket name cannot look like an IP address: $bucket_name"

  [[ \
    "$bucket_name" != xn--* &&
    "$bucket_name" != sthree-* &&
    "$bucket_name" != amzn-s3-demo-* \
  ]] || die "Bucket name uses an AWS-reserved prefix: $bucket_name"

  [[ \
    "$bucket_name" != *-s3alias &&
    "$bucket_name" != *--ol-s3 &&
    "$bucket_name" != *.mrap &&
    "$bucket_name" != *--x-s3 &&
    "$bucket_name" != *--table-s3 \
  ]] || die "Bucket name uses an AWS-reserved suffix: $bucket_name"
}

validate_object_prefixes() {
  local incoming_prefix="$1"
  local compressed_prefix="$2"

  [[ "$incoming_prefix" != /* && "$incoming_prefix" == */ ]] \
    || die "INCOMING_PREFIX must not begin with / and must end with /."

  [[ "$compressed_prefix" != /* && "$compressed_prefix" == */ ]] \
    || die "COMPRESSED_PREFIX must not begin with / and must end with /."

  [[ "$incoming_prefix" != "$compressed_prefix" ]] \
    || die "INCOMING_PREFIX and COMPRESSED_PREFIX must be different."
}

validate_bucket_arn_consistency() {
  local bucket_arn="$1"
  local expected_partition="$2"
  local expected_bucket_name="$3"
  local expected_bucket_arn="arn:$expected_partition:s3:::$expected_bucket_name"

  [[ "$bucket_arn" == "$expected_bucket_arn" ]] \
    || die "Bucket ARN is invalid or inconsistent; expected: $expected_bucket_arn"
}

validate_queue_arn_consistency() {
  local queue_arn="$1"
  local expected_partition="$2"
  local expected_region="$3"
  local expected_account_id="$4"
  local expected_queue_name="$5"
  local arn_label
  local partition
  local service
  local region
  local account_id
  local queue_name
  local extra

  IFS=: read -r \
    arn_label partition service region account_id queue_name extra \
    <<<"$queue_arn"

  [[ \
    "$arn_label" == "arn" &&
    "$service" == "sqs" &&
    -z "${extra:-}" \
  ]] || die "Queue ARN has an invalid structure: $queue_arn"

  [[ "$partition" == "$expected_partition" ]] \
    || die "Queue ARN partition '$partition' does not match caller partition '$expected_partition'."

  [[ "$region" == "$expected_region" ]] \
    || die "Queue ARN region '$region' does not match configured region '$expected_region'."

  [[ "$account_id" == "$expected_account_id" ]] \
    || die "Queue ARN account '$account_id' does not match authenticated account '$expected_account_id'."

  [[ "$queue_name" == "$expected_queue_name" ]] \
    || die "Queue ARN name '$queue_name' does not match configured queue '$expected_queue_name'."
}

validate_template_placeholders() {
  local template_file="$1"
  local placeholder
  local placeholders

  [[ -f "$template_file" ]] \
    || die "Required source template is missing: $template_file"

  jq empty "$template_file" >/dev/null 2>&1 \
    || die "Source template is not valid JSON: $template_file"

  placeholders="$(
    grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$template_file" \
      | sort -u \
      || true
  )"

  while IFS= read -r placeholder; do
    [[ -n "$placeholder" ]] || continue

    case "$placeholder" in
      '${BUCKET_ARN}'|'${QUEUE_ARN}'|'${ACCOUNT_ID}'|'${INCOMING_PREFIX}'|'${COMPRESSED_PREFIX}')
        ;;
      *)
        die "Unsupported placeholder $placeholder in template: $template_file"
        ;;
    esac
  done <<<"$placeholders"
}

validate_json_file() {
  local json_file="$1"
  local expected_bucket_arn="${2:-}"
  local expected_queue_arn="${3:-}"
  local arn_value

  [[ -f "$json_file" ]] \
    || die "Required generated JSON file is missing: $json_file"

  jq empty "$json_file" >/dev/null 2>&1 \
    || die "Generated file is not valid JSON: $json_file"

  if grep -Eq '\$\{[^}]+\}' "$json_file"; then
    die "Generated JSON contains an unresolved placeholder: $json_file"
  fi

  while IFS= read -r arn_value; do
    [[ -n "$arn_value" ]] || continue

    if [[ \
      "$arn_value" != "$expected_bucket_arn" &&
      "$arn_value" != "$expected_bucket_arn/"* &&
      "$arn_value" != "$expected_queue_arn" \
    ]]; then

      die "Generated JSON contains an unexpected or inconsistent ARN '$arn_value': $json_file"
    fi
  done < <(jq -r '.. | strings | select(startswith("arn:"))' "$json_file")
}

validate_generated_json_directory() {
  local generated_directory="$1"
  local expected_bucket_arn="$2"
  local expected_queue_arn="$3"
  shift 3
  local required_file
  local generated_file
  local generated_file_count=0

  [[ -d "$generated_directory" ]] \
    || die "Generated JSON directory is missing: $generated_directory"

  for required_file in "$@"; do
    validate_json_file \
      "$generated_directory/$required_file" \
      "$expected_bucket_arn" \
      "$expected_queue_arn"
  done

  while IFS= read -r -d '' generated_file; do
    validate_json_file \
      "$generated_file" \
      "$expected_bucket_arn" \
      "$expected_queue_arn"

    generated_file_count=$((generated_file_count + 1))
  done < <(find "$generated_directory" -maxdepth 1 -type f -name '*.json' -print0)

  (( generated_file_count > 0 )) \
    || die "No generated JSON files were found in: $generated_directory"
}

write_json_atomically() {
  local destination_file="$1"
  local destination_directory
  local temporary_file

  destination_directory="$(dirname -- "$destination_file")"
  mkdir -p "$destination_directory"
  temporary_file="$(mktemp "$destination_directory/.state.XXXXXX")"

  if ! jq . >"$temporary_file"; then
    rm -f -- "$temporary_file"
    die "Refusing to write invalid JSON state: $destination_file"
  fi

  chmod 600 "$temporary_file"
  mv "$temporary_file" "$destination_file"
}

update_json_file_atomically() {
  local state_file="$1"
  local jq_filter="$2"
  shift 2
  local temporary_file

  [[ -f "$state_file" ]] \
    || die "State file is missing: $state_file"

  temporary_file="$(mktemp "$(dirname -- "$state_file")/.state.XXXXXX")"

  if ! jq "$@" "$jq_filter" "$state_file" >"$temporary_file"; then
    rm -f -- "$temporary_file"
    die "Could not update deployment state: $state_file"
  fi

  chmod 600 "$temporary_file"
  mv "$temporary_file" "$state_file"
}

validate_deployment_state() {
  local state_file="$1"
  local account_id="$2"
  local partition="$3"
  local region="$4"
  local profile="$5"
  local project_name="$6"
  local environment="$7"
  local bucket_name="$8"
  local bucket_arn="$9"
  local queue_name="${10}"
  local queue_arn="${11}"
  local lambda_name="${12}"
  local lambda_arn="${13}"
  local role_name="${14}"
  local role_arn="${15}"
  local lambda_s3_policy_name="${16}"
  local lambda_sqs_policy_name="${17}"

  [[ -f "$state_file" ]] \
    || die "Deployment state is missing: $state_file"

  jq empty "$state_file" >/dev/null 2>&1 \
    || die "Deployment state is not valid JSON: $state_file"

  jq -e \
    --arg account_id "$account_id" \
    --arg partition "$partition" \
    --arg region "$region" \
    --arg profile "$profile" \
    --arg project_name "$project_name" \
    --arg environment "$environment" \
    --arg project_identifier "$project_name/$environment" \
    --arg bucket_name "$bucket_name" \
    --arg bucket_arn "$bucket_arn" \
    --arg queue_name "$queue_name" \
    --arg queue_arn "$queue_arn" \
    --arg lambda_name "$lambda_name" \
    --arg lambda_arn "$lambda_arn" \
    --arg role_name "$role_name" \
    --arg role_arn "$role_arn" \
    --arg lambda_s3_policy_name "$lambda_s3_policy_name" \
    --arg lambda_sqs_policy_name "$lambda_sqs_policy_name" \
    '
      .schema_version == 1 and
      (.deployment_id | type == "string" and length > 0) and
      .identity.account_id == $account_id and
      .identity.partition == $partition and
      .identity.region == $region and
      .identity.profile == $profile and
      .identity.project_name == $project_name and
      .identity.environment == $environment and
      .identity.project_identifier == $project_identifier and
      .resources.bucket.name == $bucket_name and
      .resources.bucket.arn == $bucket_arn and
      .resources.queue.name == $queue_name and
      .resources.queue.arn == $queue_arn and
      .resources.lambda.name == $lambda_name and
      .resources.lambda.arn == $lambda_arn and
      .resources.role.name == $role_name and
      .resources.role.arn == $role_arn and
      .resources.policies.lambda_s3_name == $lambda_s3_policy_name and
      .resources.policies.lambda_sqs_name == $lambda_sqs_policy_name
    ' \
    "$state_file" >/dev/null \
    || die "Deployment state does not match the authenticated account, configuration, or deterministic resource names: $state_file"
}

refuse_resource_collision() {
  local resource_type="$1"
  local resource_name="$2"
  local inspection_command="$3"

  die "Resource collision: $resource_type already exists: $resource_name. This deployment will not adopt, overwrite, or delete it. Inspect it with: $inspection_command"
}

validate_typed_confirmation() {
  local provided_confirmation="$1"
  local expected_confirmation="$2"

  [[ "$provided_confirmation" == "$expected_confirmation" ]] \
    || die "Confirmation did not match. Expected exactly: $expected_confirmation"
}
