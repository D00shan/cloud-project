#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="${1:-$SCRIPT_DIR/.env}"
TEMPLATE_DIR="$SCRIPT_DIR/config/templates"
BUILD_DIR="$SCRIPT_DIR/build"
OUTPUT_DIR="$BUILD_DIR/generated-config"
staging_directory=""

cleanup() {
  if [[ -n "$staging_directory" && -d "$staging_directory" ]]; then
    rm -rf -- "$staging_directory"
  fi
}

trap cleanup EXIT

require_command jq
require_command grep
require_command find
require_command mktemp

[[ -f "$CONFIG_FILE" ]] \
  || die "Config file not found: $CONFIG_FILE. Copy config/project.env.example to .env first."

# The configuration file is a local, trusted Bash-style environment file.
set -a

# shellcheck disable=SC1090
source "$CONFIG_FILE"

set +a

for variable_name in \
  ACCOUNT_ID \
  BUCKET_ARN \
  QUEUE_ARN \
  INCOMING_PREFIX \
  COMPRESSED_PREFIX; do

  require_config_value "$variable_name"
done

[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] \
  || die "ACCOUNT_ID must contain exactly 12 digits."

[[ "$BUCKET_ARN" =~ ^arn:(aws|aws-us-gov|aws-cn):s3:::[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] \
  || die "BUCKET_ARN is not a supported S3 bucket ARN: $BUCKET_ARN"

[[ "$QUEUE_ARN" =~ ^arn:(aws|aws-us-gov|aws-cn):sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$ ]] \
  || die "QUEUE_ARN is not a supported SQS queue ARN: $QUEUE_ARN"

[[ "$QUEUE_ARN" == *":$ACCOUNT_ID:"* ]] \
  || die "QUEUE_ARN does not belong to ACCOUNT_ID $ACCOUNT_ID."

[[ "$INCOMING_PREFIX" != /* && "$INCOMING_PREFIX" == */ ]] \
  || die "INCOMING_PREFIX must not begin with / and must end with /."

[[ "$COMPRESSED_PREFIX" != /* && "$COMPRESSED_PREFIX" == */ ]] \
  || die "COMPRESSED_PREFIX must not begin with / and must end with /."

[[ "$INCOMING_PREFIX" != "$COMPRESSED_PREFIX" ]] \
  || die "INCOMING_PREFIX and COMPRESSED_PREFIX must be different."

validate_template_placeholders() {
  local template_file="$1"
  local placeholder
  local placeholders

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

render_template() {
  local source_file="$1"
  local destination_file="$2"

  [[ -f "$source_file" ]] \
    || die "Required source template is missing: $source_file"

  validate_template_placeholders "$source_file"

  jq \
    --arg bucket_arn "$BUCKET_ARN" \
    --arg queue_arn "$QUEUE_ARN" \
    --arg account_id "$ACCOUNT_ID" \
    --arg incoming_prefix "$INCOMING_PREFIX" \
    --arg compressed_prefix "$COMPRESSED_PREFIX" \
    '
      def replace_token($token; $value):
        split($token) | join($value);

      walk(
        if type == "string" then
          replace_token("${BUCKET_ARN}"; $bucket_arn)
          | replace_token("${QUEUE_ARN}"; $queue_arn)
          | replace_token("${ACCOUNT_ID}"; $account_id)
          | replace_token("${INCOMING_PREFIX}"; $incoming_prefix)
          | replace_token("${COMPRESSED_PREFIX}"; $compressed_prefix)
        else
          .
        end
      )
    ' \
    "$source_file" >"$destination_file"
}

mkdir -p "$BUILD_DIR"
staging_directory="$(mktemp -d "$BUILD_DIR/.generated-config.XXXXXX")"

render_template \
  "$TEMPLATE_DIR/lambda-s3-policy.json.template" \
  "$staging_directory/lambda-s3-policy.json"

render_template \
  "$TEMPLATE_DIR/lambda-sqs-policy.json.template" \
  "$staging_directory/lambda-sqs-policy.json"

render_template \
  "$TEMPLATE_DIR/sqs-resource-policy.json.template" \
  "$staging_directory/sqs-resource-policy.json"

render_template \
  "$TEMPLATE_DIR/s3-notification.json.template" \
  "$staging_directory/s3-notification.json"

[[ -f "$TEMPLATE_DIR/lambda-trust-policy.json" ]] \
  || die "Required static trust policy is missing: $TEMPLATE_DIR/lambda-trust-policy.json"

validate_template_placeholders "$TEMPLATE_DIR/lambda-trust-policy.json"
cp "$TEMPLATE_DIR/lambda-trust-policy.json" \
  "$staging_directory/lambda-trust-policy.json"

required_generated_files=(
  lambda-trust-policy.json
  lambda-s3-policy.json
  lambda-sqs-policy.json
  sqs-resource-policy.json
  s3-notification.json
)

validate_generated_json_directory \
  "$staging_directory" \
  "${required_generated_files[@]}"

[[ "$OUTPUT_DIR" == "$SCRIPT_DIR/build/generated-config" ]] \
  || die "Refusing to replace unexpected output directory: $OUTPUT_DIR"

rm -rf -- "$OUTPUT_DIR"
mv "$staging_directory" "$OUTPUT_DIR"
staging_directory=""

log "Rendered and validated JSON configuration:"

for generated_file in "${required_generated_files[@]}"; do
  log "  $OUTPUT_DIR/$generated_file"
done

log "Rendering completed locally. No AWS resources were changed."
