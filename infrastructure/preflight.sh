#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="${1:-$SCRIPT_DIR/.env}"

# Prevent AWS CLI from opening output in a pager.
export AWS_PAGER=""

log "Running infrastructure preflight checks..."

# ---------------------------------------------------------------------------
# Local configuration and command checks
# ---------------------------------------------------------------------------

[[ -f "$CONFIG_FILE" ]] \
  || die "Config file not found: $CONFIG_FILE. Copy config/project.env.example to .env first."

for command_name in aws node npm zip jq; do
  require_command "$command_name"
done

AWS_CLI_VERSION="$(aws --version 2>&1)"

[[ "$AWS_CLI_VERSION" == aws-cli/2.* ]] \
  || die "AWS CLI v2 is required; found: $AWS_CLI_VERSION"

aws s3api create-bucket --generate-cli-skeleton input \
  | jq -e '.CreateBucketConfiguration.Tags' >/dev/null \
  || die "Installed AWS CLI does not support tagging during create-bucket. Upgrade AWS CLI v2 before deploying."

# The configuration file is a local, trusted Bash-style environment file.
set -a

# shellcheck disable=SC1090
source "$CONFIG_FILE"

set +a

required_values=(
  AWS_PROFILE
  AWS_REGION
  PROJECT_NAME
  ENVIRONMENT
  BUCKET_NAME_PREFIX
  INCOMING_PREFIX
  COMPRESSED_PREFIX
  SQS_QUEUE_NAME
  SQS_VISIBILITY_TIMEOUT
  LAMBDA_FUNCTION_NAME
  LAMBDA_ROLE_NAME
  LAMBDA_RUNTIME
  LAMBDA_MEMORY_SIZE
  LAMBDA_TIMEOUT
)

for variable_name in "${required_values[@]}"; do
  require_config_value "$variable_name"
done

# ---------------------------------------------------------------------------
# Configuration validation
# ---------------------------------------------------------------------------

validate_aws_region "$AWS_REGION"

[[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] \
  || die "PROJECT_NAME must use lowercase letters, numbers, and hyphens."

[[ "$ENVIRONMENT" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] \
  || die "ENVIRONMENT must use lowercase letters, numbers, and hyphens."

[[ "$BUCKET_NAME_PREFIX" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] \
  || die "BUCKET_NAME_PREFIX must use lowercase letters, numbers, and hyphens."

[[ "$SQS_QUEUE_NAME" =~ ^[A-Za-z0-9_-]{1,80}$ ]] \
  || die "SQS_QUEUE_NAME must be 1-80 characters using letters, numbers, hyphens, or underscores."

[[ "$LAMBDA_FUNCTION_NAME" =~ ^[A-Za-z0-9_-]{1,64}$ ]] \
  || die "LAMBDA_FUNCTION_NAME must be 1-64 characters using letters, numbers, hyphens, or underscores."

[[ "$LAMBDA_ROLE_NAME" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] \
  || die "LAMBDA_ROLE_NAME contains unsupported characters or is longer than 64 characters."

[[ "$LAMBDA_RUNTIME" =~ ^nodejs[0-9]+\.x$ ]] \
  || die "LAMBDA_RUNTIME must be an AWS Node.js runtime such as nodejs22.x."

validate_object_prefixes "$INCOMING_PREFIX" "$COMPRESSED_PREFIX"

require_integer_between SQS_VISIBILITY_TIMEOUT 0 43200
require_integer_between LAMBDA_MEMORY_SIZE 128 10240
require_integer_between LAMBDA_TIMEOUT 1 900

minimum_visibility_timeout=$((LAMBDA_TIMEOUT * 6))

(( SQS_VISIBILITY_TIMEOUT >= minimum_visibility_timeout )) \
  || die "SQS_VISIBILITY_TIMEOUT must be at least six times LAMBDA_TIMEOUT ($minimum_visibility_timeout seconds)."

# ---------------------------------------------------------------------------
# AWS identity and region checks
# ---------------------------------------------------------------------------

log "Authenticating with AWS profile '$AWS_PROFILE' in region '$AWS_REGION'..."

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

# ---------------------------------------------------------------------------
# Bucket-name generation and validation
# ---------------------------------------------------------------------------

BUCKET_NAME="${BUCKET_NAME_PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"
validate_bucket_name "$BUCKET_NAME"

log "AWS account: $ACCOUNT_ID"
log "Caller ARN:  $CALLER_ARN"
log "AWS region:  $AWS_REGION"
log "Bucket name: $BUCKET_NAME"

# ---------------------------------------------------------------------------
# Conservative bucket availability check
# ---------------------------------------------------------------------------

bucket_error_file="$(mktemp)"

trap 'rm -f "$bucket_error_file"' EXIT

if aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  s3api head-bucket \
  --bucket "$BUCKET_NAME" \
  --no-cli-pager \
  >/dev/null 2>"$bucket_error_file"; then

  if [[ "${PREFLIGHT_ALLOW_CONFIGURED_BUCKET:-0}" == "1" ]]; then
    log "Configured bucket already exists and is accessible; deployment state must prove ownership."
  else
    die "Bucket name is already in use and accessible: $BUCKET_NAME"
  fi

  log "Preflight passed. No AWS resources were changed."
  exit 0
fi

bucket_error="$(<"$bucket_error_file")"

if grep -Eq '\(404\)|Not Found|NoSuchBucket' <<<"$bucket_error"; then
  log "Bucket name appears available in the AWS partition."

elif grep -Eq \
  '\(400\)|\(403\)|Forbidden|AccessDenied|Bad Request|Moved Permanently' \
  <<<"$bucket_error"; then

  die "Bucket name is unavailable or AWS cannot prove it is available: $BUCKET_NAME. AWS response: $bucket_error"

else
  die "Could not determine bucket-name availability. AWS response: $bucket_error"
fi

log "Preflight passed. No AWS resources were changed."
