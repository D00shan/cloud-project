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
previous_output_directory=""

cleanup() {
  if [[ -n "$staging_directory" && -d "$staging_directory" ]]; then
    rm -rf -- "$staging_directory"
  fi

  if [[ -n "$previous_output_directory" && -e "$previous_output_directory" ]]; then
    if [[ ! -e "$OUTPUT_DIR" ]]; then
      mv "$previous_output_directory" "$OUTPUT_DIR"
    else
      rm -rf -- "$previous_output_directory"
    fi
  fi
}

trap cleanup EXIT

require_command jq
require_command grep
require_command find
require_command mktemp
require_command aws

[[ -f "$CONFIG_FILE" ]] \
  || die "Config file not found: $CONFIG_FILE. Copy config/project.env.example to .env first."

# The configuration file is a local, trusted Bash-style environment file.
set -a

# shellcheck disable=SC1090
source "$CONFIG_FILE"

set +a

for variable_name in \
  AWS_PROFILE \
  AWS_REGION \
  BUCKET_NAME_PREFIX \
  SQS_QUEUE_NAME \
  INCOMING_PREFIX \
  COMPRESSED_PREFIX; do

  require_config_value "$variable_name"
done

validate_aws_region "$AWS_REGION"
validate_object_prefixes "$INCOMING_PREFIX" "$COMPRESSED_PREFIX"

[[ "$SQS_QUEUE_NAME" =~ ^[A-Za-z0-9_-]{1,80}$ ]] \
  || die "SQS_QUEUE_NAME must be 1-80 characters using letters, numbers, hyphens, or underscores."

export AWS_PAGER=""

log "Deriving portable resource identifiers with AWS profile '$AWS_PROFILE' in region '$AWS_REGION'..."

if ! IDENTITY_JSON="$(
  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    sts get-caller-identity \
    --output json \
    --no-cli-pager 2>&1
)"; then
  die "AWS authentication failed for profile '$AWS_PROFILE': $IDENTITY_JSON"
fi

ACCOUNT_ID="$(jq -r '.Account // empty' <<<"$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn // empty' <<<"$IDENTITY_JSON")"

validate_account_id "$ACCOUNT_ID"

[[ -n "$CALLER_ARN" ]] \
  || die "AWS did not return a caller ARN."

IFS=: read -r \
  caller_arn_label AWS_PARTITION caller_service caller_region \
  caller_account_id caller_resource \
  <<<"$CALLER_ARN"

[[ \
  "$caller_arn_label" == "arn" &&
  ( "$caller_service" == "iam" || "$caller_service" == "sts" ) &&
  -z "$caller_region" &&
  -n "$caller_resource" \
]] || die "AWS returned a structurally invalid caller ARN: $CALLER_ARN"

validate_aws_partition "$AWS_PARTITION"

[[ "$caller_account_id" == "$ACCOUNT_ID" ]] \
  || die "Caller ARN account does not match the authenticated account ID."

BUCKET_NAME="${BUCKET_NAME_PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"
validate_bucket_name "$BUCKET_NAME"

BUCKET_ARN="arn:$AWS_PARTITION:s3:::$BUCKET_NAME"
QUEUE_ARN="arn:$AWS_PARTITION:sqs:$AWS_REGION:$ACCOUNT_ID:$SQS_QUEUE_NAME"

validate_bucket_arn_consistency \
  "$BUCKET_ARN" \
  "$AWS_PARTITION" \
  "$BUCKET_NAME"

validate_queue_arn_consistency \
  "$QUEUE_ARN" \
  "$AWS_PARTITION" \
  "$AWS_REGION" \
  "$ACCOUNT_ID" \
  "$SQS_QUEUE_NAME"

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
  "$BUCKET_ARN" \
  "$QUEUE_ARN" \
  "${required_generated_files[@]}"

[[ "$OUTPUT_DIR" == "$SCRIPT_DIR/build/generated-config" ]] \
  || die "Refusing to replace unexpected output directory: $OUTPUT_DIR"

if [[ -e "$OUTPUT_DIR" ]]; then
  previous_output_directory="$BUILD_DIR/.generated-config.previous.$$"

  [[ ! -e "$previous_output_directory" ]] \
    || die "Refusing to overwrite unexpected backup path: $previous_output_directory"

  mv "$OUTPUT_DIR" "$previous_output_directory"
fi

if ! mv "$staging_directory" "$OUTPUT_DIR"; then
  die "Could not publish generated JSON; the previous valid output will be restored."
fi

staging_directory=""

if [[ -n "$previous_output_directory" ]]; then
  rm -rf -- "$previous_output_directory"
  previous_output_directory=""
fi

log "Rendered and validated JSON configuration:"

for generated_file in "${required_generated_files[@]}"; do
  log "  $OUTPUT_DIR/$generated_file"
done

log "AWS account: $ACCOUNT_ID"
log "AWS partition: $AWS_PARTITION"
log "Bucket ARN: $BUCKET_ARN"
log "Queue ARN: $QUEUE_ARN"
log "Rendering completed locally. No AWS resources were changed."
