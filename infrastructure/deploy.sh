#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="${1:-$SCRIPT_DIR/.env}"
STATE_FILE="$SCRIPT_DIR/state/deployment.json"
GENERATED_DIR="$SCRIPT_DIR/build/generated-config"
ZIP_FILE="$SCRIPT_DIR/build/lambda-package/compression-handler.zip"

export AWS_PAGER=""

[[ -f "$CONFIG_FILE" ]] \
  || die "Config file not found: $CONFIG_FILE. Copy config/project.env.example to .env first."

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

for command_name in aws jq npm zip unzip sha256sum openssl base64; do
  require_command "$command_name"
done

if [[ -f "$STATE_FILE" ]]; then
  log "Existing deployment state found; preflight will permit only the recorded bucket name."
  PREFLIGHT_ALLOW_CONFIGURED_BUCKET=1 "$SCRIPT_DIR/preflight.sh" "$CONFIG_FILE"
else
  "$SCRIPT_DIR/preflight.sh" "$CONFIG_FILE"
fi

log "Authenticating deployment identity..."

IDENTITY_JSON="$(
  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    sts get-caller-identity \
    --output json \
    --no-cli-pager
)"

ACCOUNT_ID="$(jq -r '.Account // empty' <<<"$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn // empty' <<<"$IDENTITY_JSON")"

validate_account_id "$ACCOUNT_ID"

IFS=: read -r \
  caller_arn_label AWS_PARTITION caller_service caller_region \
  caller_account_id caller_resource \
  <<<"$CALLER_ARN"

[[ \
  "$caller_arn_label" == "arn" &&
  ( "$caller_service" == "iam" || "$caller_service" == "sts" ) &&
  -z "$caller_region" &&
  "$caller_account_id" == "$ACCOUNT_ID" &&
  -n "$caller_resource" \
]] || die "AWS returned an inconsistent caller identity: $CALLER_ARN"

validate_aws_partition "$AWS_PARTITION"
validate_aws_region "$AWS_REGION"
validate_object_prefixes "$INCOMING_PREFIX" "$COMPRESSED_PREFIX"

PROJECT_IDENTIFIER="$PROJECT_NAME/$ENVIRONMENT"
BUCKET_NAME="${BUCKET_NAME_PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"
BUCKET_ARN="arn:$AWS_PARTITION:s3:::$BUCKET_NAME"
QUEUE_ARN="arn:$AWS_PARTITION:sqs:$AWS_REGION:$ACCOUNT_ID:$SQS_QUEUE_NAME"
LAMBDA_FUNCTION_ARN="arn:$AWS_PARTITION:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME"
LAMBDA_ROLE_ARN="arn:$AWS_PARTITION:iam::$ACCOUNT_ID:role/$LAMBDA_ROLE_NAME"
LAMBDA_S3_POLICY_NAME="$LAMBDA_ROLE_NAME-s3-access"
LAMBDA_SQS_POLICY_NAME="$LAMBDA_ROLE_NAME-sqs-access"
LOGGING_POLICY_ARN="arn:$AWS_PARTITION:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
LAMBDA_HANDLER="index.handler"
LAMBDA_ARCHITECTURE="x86_64"

validate_bucket_name "$BUCKET_NAME"
validate_bucket_arn_consistency "$BUCKET_ARN" "$AWS_PARTITION" "$BUCKET_NAME"
validate_queue_arn_consistency \
  "$QUEUE_ARN" "$AWS_PARTITION" "$AWS_REGION" "$ACCOUNT_ID" "$SQS_QUEUE_NAME"

state_flag() {
  local jq_path="$1"
  jq -r "$jq_path // false" "$STATE_FILE"
}

state_update() {
  local jq_filter="$1"
  shift
  update_json_file_atomically "$STATE_FILE" "$jq_filter" "$@"
}

validate_event_source_mapping_json() {
  local mapping_json="$1"

  jq -e \
    --arg queue_arn "$QUEUE_ARN" \
    --arg function_arn "$LAMBDA_FUNCTION_ARN" \
    '
      .EventSourceArn == $queue_arn and
      (.FunctionArn == $function_arn or
       .FunctionArn == ($function_arn + ":$LATEST")) and
      .BatchSize == 1 and
      .FunctionResponseTypes == ["ReportBatchItemFailures"]
    ' <<<"$mapping_json" >/dev/null
}

verify_tag_array() {
  local json="$1"
  local tags_path="$2"
  local deployment_id="$3"

  jq -e \
    --arg deployment_id "$deployment_id" \
    --arg project "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    "
      $tags_path
      | (map(select(.Key == \"DeploymentId\"))[0].Value == \$deployment_id) and
        (map(select(.Key == \"Project\"))[0].Value == \$project) and
        (map(select(.Key == \"Environment\"))[0].Value == \$environment)
    " \
    <<<"$json" >/dev/null
}

verify_tag_map() {
  local json="$1"
  local tags_path="$2"
  local deployment_id="$3"

  jq -e \
    --arg deployment_id "$deployment_id" \
    --arg project "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    "
      $tags_path.DeploymentId == \$deployment_id and
      $tags_path.Project == \$project and
      $tags_path.Environment == \$environment
    " \
    <<<"$json" >/dev/null
}

s3_bucket_status() {
  local error_file
  error_file="$(mktemp)"

  if aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    s3api head-bucket \
    --bucket "$BUCKET_NAME" \
    --no-cli-pager \
    >/dev/null 2>"$error_file"; then

    rm -f -- "$error_file"
    return 0
  fi

  if grep -Eq '\(404\)|Not Found|NoSuchBucket' "$error_file"; then
    rm -f -- "$error_file"
    return 1
  fi

  warn "AWS could not prove that bucket '$BUCKET_NAME' is absent."
  sed 's/^/[AWS] /' "$error_file" >&2
  rm -f -- "$error_file"
  return 2
}

queue_lookup() {
  local error_file
  error_file="$(mktemp)"

  if aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    sqs get-queue-url \
    --queue-name "$SQS_QUEUE_NAME" \
    --output json \
    --no-cli-pager 2>"$error_file"; then

    rm -f -- "$error_file"
    return 0
  fi

  if grep -Eq 'NonExistentQueue|QueueDoesNotExist' "$error_file"; then
    rm -f -- "$error_file"
    return 1
  fi

  sed 's/^/[AWS] /' "$error_file" >&2
  rm -f -- "$error_file"
  return 2
}

role_lookup() {
  local error_file
  error_file="$(mktemp)"

  if aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    iam get-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --output json \
    --no-cli-pager 2>"$error_file"; then

    rm -f -- "$error_file"
    return 0
  fi

  if grep -Eq 'NoSuchEntity' "$error_file"; then
    rm -f -- "$error_file"
    return 1
  fi

  sed 's/^/[AWS] /' "$error_file" >&2
  rm -f -- "$error_file"
  return 2
}

lambda_lookup() {
  local error_file
  error_file="$(mktemp)"

  if aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    lambda get-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --output json \
    --no-cli-pager 2>"$error_file"; then

    rm -f -- "$error_file"
    return 0
  fi

  if grep -Eq 'ResourceNotFoundException' "$error_file"; then
    rm -f -- "$error_file"
    return 1
  fi

  sed 's/^/[AWS] /' "$error_file" >&2
  rm -f -- "$error_file"
  return 2
}

RESUMING=false

if [[ -f "$STATE_FILE" ]]; then
  validate_deployment_state \
    "$STATE_FILE" \
    "$ACCOUNT_ID" "$AWS_PARTITION" "$AWS_REGION" "$AWS_PROFILE" \
    "$PROJECT_NAME" "$ENVIRONMENT" \
    "$BUCKET_NAME" "$BUCKET_ARN" \
    "$SQS_QUEUE_NAME" "$QUEUE_ARN" \
    "$LAMBDA_FUNCTION_NAME" "$LAMBDA_FUNCTION_ARN" \
    "$LAMBDA_ROLE_NAME" "$LAMBDA_ROLE_ARN" \
    "$LAMBDA_S3_POLICY_NAME" "$LAMBDA_SQS_POLICY_NAME"

  DEPLOYMENT_ID="$(jq -r '.deployment_id' "$STATE_FILE")"
  RESUMING=true
  log "Validated interrupted/existing deployment state: $DEPLOYMENT_ID"
else
  DEPLOYMENT_ID="$PROJECT_NAME-$ENVIRONMENT-$(date -u +%Y%m%dT%H%M%SZ)"
fi

log "Checking deterministic resource names for collisions..."

adopt_bucket=false
adopt_queue=false
adopt_role=false
bucket_exists=false
if s3_bucket_status; then
  bucket_exists=true
elif (( $? == 2 )); then
  die "Refusing deployment because bucket ownership/availability is ambiguous: $BUCKET_NAME. Inspect it with aws s3api head-bucket."
fi

queue_json=""
if queue_json="$(queue_lookup)"; then
  queue_exists=true
else
  lookup_status=$?
  [[ "$lookup_status" == "1" ]] \
    || die "Could not safely determine whether SQS queue '$SQS_QUEUE_NAME' exists."
  queue_exists=false
fi

role_json=""
if role_json="$(role_lookup)"; then
  role_exists=true
else
  lookup_status=$?
  [[ "$lookup_status" == "1" ]] \
    || die "Could not safely determine whether IAM role '$LAMBDA_ROLE_NAME' exists."
  role_exists=false
fi

lambda_json=""
if lambda_json="$(lambda_lookup)"; then
  lambda_exists=true
else
  lookup_status=$?
  [[ "$lookup_status" == "1" ]] \
    || die "Could not safely determine whether Lambda function '$LAMBDA_FUNCTION_NAME' exists."
  lambda_exists=false
fi

if [[ "$RESUMING" == false ]]; then
  if [[ "$bucket_exists" == true ]]; then
    refuse_resource_collision \
      "S3 bucket" "$BUCKET_NAME" \
      "aws --profile $AWS_PROFILE --region $AWS_REGION s3api head-bucket --bucket $BUCKET_NAME"
  fi

  if [[ "$queue_exists" == true ]]; then
    refuse_resource_collision \
      "SQS queue" "$SQS_QUEUE_NAME" \
      "aws --profile $AWS_PROFILE --region $AWS_REGION sqs get-queue-url --queue-name $SQS_QUEUE_NAME"
  fi

  if [[ "$role_exists" == true ]]; then
    refuse_resource_collision \
      "IAM role" "$LAMBDA_ROLE_NAME" \
      "aws --profile $AWS_PROFILE --region $AWS_REGION iam get-role --role-name $LAMBDA_ROLE_NAME"
  fi

  if [[ "$lambda_exists" == true ]]; then
    refuse_resource_collision \
      "Lambda function" "$LAMBDA_FUNCTION_NAME" \
      "aws --profile $AWS_PROFILE --region $AWS_REGION lambda get-function --function-name $LAMBDA_FUNCTION_NAME"
  fi
else
  DEPLOYMENT_TAG_ID="$DEPLOYMENT_ID"

  if [[ "$bucket_exists" == true ]]; then
    bucket_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api get-bucket-tagging --bucket "$BUCKET_NAME" \
        --output json --no-cli-pager
    )"

    verify_tag_array "$bucket_tags" '.TagSet' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded bucket ownership tags do not match deployment state: $BUCKET_NAME"

    bucket_location="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api get-bucket-location --bucket "$BUCKET_NAME" \
        --query LocationConstraint --output text --no-cli-pager
    )"
    [[ "$bucket_location" == "None" ]] && bucket_location="us-east-1"
    [[ "$bucket_location" == "$AWS_REGION" ]] \
      || die "Resource collision: owned bucket region '$bucket_location' does not match '$AWS_REGION'."

    if [[ "$(state_flag '.resources.bucket.created')" != true ]]; then
      adopt_bucket=true
    fi
  elif [[ "$(state_flag '.resources.bucket.created')" == true ]]; then
    die "State records bucket creation, but the bucket no longer exists: $BUCKET_NAME"
  fi

  if [[ "$queue_exists" == true ]]; then
    recorded_queue_url="$(jq -r '.resources.queue.url // empty' "$STATE_FILE")"
    actual_queue_url="$(jq -r '.QueueUrl // empty' <<<"$queue_json")"
    [[ -n "$actual_queue_url" ]] \
      || die "Resource collision: existing SQS queue lookup returned no URL."
    [[ -z "$recorded_queue_url" || "$actual_queue_url" == "$recorded_queue_url" ]] \
      || die "Recorded SQS queue URL does not match the existing queue."

    queue_attributes_json="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        sqs get-queue-attributes --queue-url "$actual_queue_url" \
        --attribute-names QueueArn VisibilityTimeout Policy \
        --output json --no-cli-pager
    )"
    actual_queue_arn="$(jq -r '.Attributes.QueueArn // empty' <<<"$queue_attributes_json")"
    actual_visibility_timeout="$(
      jq -r '.Attributes.VisibilityTimeout // empty' <<<"$queue_attributes_json"
    )"
    [[ "$actual_queue_arn" == "$QUEUE_ARN" ]] \
      || die "Resource collision: existing queue ARN does not match $QUEUE_ARN."
    [[ "$actual_visibility_timeout" == "$SQS_VISIBILITY_TIMEOUT" ]] \
      || die "Resource collision: existing queue visibility timeout does not match configured value."

    queue_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        sqs list-queue-tags --queue-url "$actual_queue_url" \
        --output json --no-cli-pager
    )"

    verify_tag_map "$queue_tags" '.Tags' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded queue ownership tags do not match deployment state: $SQS_QUEUE_NAME"

    if [[ "$(state_flag '.resources.queue.created')" != true ]]; then
      adopt_queue=true
    fi
  elif [[ "$(state_flag '.resources.queue.created')" == true ]]; then
    die "State records queue creation, but the queue no longer exists: $SQS_QUEUE_NAME"
  fi

  if [[ "$role_exists" == true ]]; then
    actual_role_arn="$(jq -r '.Role.Arn // empty' <<<"$role_json")"
    [[ "$actual_role_arn" == "$LAMBDA_ROLE_ARN" ]] \
      || die "Resource collision: existing IAM role ARN does not match $LAMBDA_ROLE_ARN."

    actual_trust_policy="$(
      jq -cS '.Role.AssumeRolePolicyDocument // empty' <<<"$role_json"
    )"
    expected_trust_policy="$(
      jq -cS . "$SCRIPT_DIR/config/templates/lambda-trust-policy.json"
    )"
    [[ "$actual_trust_policy" == "$expected_trust_policy" ]] \
      || die "Resource collision: existing IAM role trust policy does not match."

    role_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        iam list-role-tags --role-name "$LAMBDA_ROLE_NAME" \
        --output json --no-cli-pager
    )"

    verify_tag_array "$role_tags" '.Tags' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded role ownership tags do not match deployment state: $LAMBDA_ROLE_NAME"

    if [[ "$(state_flag '.resources.role.created')" != true ]]; then
      adopt_role=true
    fi
  elif [[ "$(state_flag '.resources.role.created')" == true ]]; then
    die "State records role creation, but the role no longer exists: $LAMBDA_ROLE_NAME"
  fi

  if [[ "$lambda_exists" == true ]]; then
    actual_lambda_arn="$(
      jq -r '.Configuration.FunctionArn // empty' <<<"$lambda_json"
    )"
    [[ "$actual_lambda_arn" == "$LAMBDA_FUNCTION_ARN" ]] \
      || die "Resource collision: existing Lambda ARN does not match $LAMBDA_FUNCTION_ARN."

    function_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        lambda list-tags --resource "$LAMBDA_FUNCTION_ARN" \
        --output json --no-cli-pager
    )"

    verify_tag_map "$function_tags" '.Tags' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded function ownership tags do not match deployment state: $LAMBDA_FUNCTION_NAME"
  elif [[ "$(state_flag '.resources.lambda.created')" == true ]]; then
    die "State records Lambda creation, but the function no longer exists: $LAMBDA_FUNCTION_NAME"
  fi
fi

log "Rendering deployment JSON before any resource mutation..."
"$SCRIPT_DIR/render-templates.sh" "$CONFIG_FILE"

log "Building Lambda deployment package..."
"$SCRIPT_DIR/package-lambda.sh"

# Conservative rerun policy:
# This script reapplies only configuration that is known to be safe on
# proven-owned resources; it is not a complete reconciler. Record a normalized
# configuration fingerprint and the exact Lambda package hash on first deploy.
# A rerun must match both values before the first AWS mutation, otherwise the
# temporary stack must be destroyed and recreated.
normalized_deployment_configuration="$(
  GENERATED_CONFIGURATION_SHA256="$(
    (
      cd "$GENERATED_DIR"
      sha256sum ./*.json
    ) | sha256sum | awk '{print $1}'
  )"

  jq -ncS \
    --arg aws_profile "$AWS_PROFILE" \
    --arg aws_region "$AWS_REGION" \
    --arg project_name "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    --arg bucket_name_prefix "$BUCKET_NAME_PREFIX" \
    --arg incoming_prefix "$INCOMING_PREFIX" \
    --arg compressed_prefix "$COMPRESSED_PREFIX" \
    --arg sqs_queue_name "$SQS_QUEUE_NAME" \
    --arg sqs_visibility_timeout "$SQS_VISIBILITY_TIMEOUT" \
    --arg lambda_function_name "$LAMBDA_FUNCTION_NAME" \
    --arg lambda_role_name "$LAMBDA_ROLE_NAME" \
    --arg lambda_runtime "$LAMBDA_RUNTIME" \
    --arg lambda_handler "$LAMBDA_HANDLER" \
    --arg lambda_architecture "$LAMBDA_ARCHITECTURE" \
    --arg lambda_memory_size "$LAMBDA_MEMORY_SIZE" \
    --arg lambda_timeout "$LAMBDA_TIMEOUT" \
    --arg generated_configuration_sha256 "$GENERATED_CONFIGURATION_SHA256" \
    '{
      aws_profile:$aws_profile,
      aws_region:$aws_region,
      project_name:$project_name,
      environment:$environment,
      bucket_name_prefix:$bucket_name_prefix,
      incoming_prefix:$incoming_prefix,
      compressed_prefix:$compressed_prefix,
      sqs_queue_name:$sqs_queue_name,
      sqs_visibility_timeout:$sqs_visibility_timeout,
      lambda_function_name:$lambda_function_name,
      lambda_role_name:$lambda_role_name,
      lambda_runtime:$lambda_runtime,
      lambda_handler:$lambda_handler,
      lambda_architecture:$lambda_architecture,
      lambda_memory_size:$lambda_memory_size,
      lambda_timeout:$lambda_timeout,
      generated_configuration_sha256:$generated_configuration_sha256,
      s3_object_ownership:"BucketOwnerEnforced",
      s3_public_access_block:"all-blocked",
      s3_default_encryption:"AES256"
    }'
)"

CONFIGURATION_FINGERPRINT="$(
  sha256sum <<<"$normalized_deployment_configuration" | awk '{print $1}'
)"
LAMBDA_PACKAGE_SHA256="$(sha256sum "$ZIP_FILE" | awk '{print $1}')"
LAMBDA_PACKAGE_CODE_SHA256="$(
  openssl dgst -sha256 -binary "$ZIP_FILE" | base64 | tr -d '\n'
)"

if [[ "$RESUMING" == true ]]; then
  recorded_configuration_fingerprint="$(
    jq -r '.deployment_configuration_fingerprint // empty' "$STATE_FILE"
  )"
  recorded_lambda_package_sha256="$(
    jq -r '.lambda_package_sha256 // empty' "$STATE_FILE"
  )"

  [[ -n "$recorded_configuration_fingerprint" ]] \
    || die "Existing state predates the rerun fingerprint policy. Destroy the temporary stack with the recorded configuration, then deploy it again."

  [[ "$CONFIGURATION_FINGERPRINT" == "$recorded_configuration_fingerprint" ]] \
    || die "Deployment configuration changed since this stack was created. Refusing a partial reconciliation. Destroy the temporary stack with ./infrastructure/destroy.sh, then deploy it again."

  [[ -n "$recorded_lambda_package_sha256" ]] \
    || die "Existing state does not record a Lambda package hash. Destroy the temporary stack, then deploy it again."

  [[ "$LAMBDA_PACKAGE_SHA256" == "$recorded_lambda_package_sha256" ]] \
    || die "Lambda package content changed since this stack was created. Refusing to leave mixed code/configuration. Destroy the temporary stack with ./infrastructure/destroy.sh, then deploy it again."

  log "Rerun fingerprints match recorded deployment configuration and Lambda package."

fi

if [[ "$RESUMING" == true ]]; then
  # Validate every mutable integration that may have succeeded immediately
  # before a crash. Exact matches can be checkpointed; mismatches are
  # collisions and must fail before any AWS mutation.
  if [[ "$queue_exists" == true ]]; then
    actual_queue_policy="$(
      jq -r '.Attributes.Policy // empty' <<<"$queue_attributes_json"
    )"

    if [[ -n "$actual_queue_policy" ]]; then
      actual_queue_policy_canonical="$(jq -cS . <<<"$actual_queue_policy")"
      expected_queue_policy_canonical="$(
        jq -cS . "$GENERATED_DIR/sqs-resource-policy.json"
      )"
      [[ "$actual_queue_policy_canonical" == "$expected_queue_policy_canonical" ]] \
        || die "Resource collision: existing SQS queue policy differs from the rendered deployment policy."
      state_update '.steps.queue_policy_applied = true'
    fi
    if [[ "$adopt_queue" == true ]]; then
      state_update \
        '.resources.queue.created = true | .resources.queue.url = $queue_url' \
        --arg queue_url "$actual_queue_url"
      log "Adopted exactly matching tagged SQS queue into deployment state."
    fi
  fi

  if [[ "$role_exists" == true ]]; then
    attached_policies="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        iam list-attached-role-policies --role-name "$LAMBDA_ROLE_NAME" \
        --output json --no-cli-pager
    )"
    unexpected_managed_policy_count="$(
      jq \
        --arg expected "$LOGGING_POLICY_ARN" \
        '[.AttachedPolicies[]? | select(.PolicyArn != $expected)] | length' \
        <<<"$attached_policies"
    )"
    [[ "$unexpected_managed_policy_count" == "0" ]] \
      || die "Resource collision: owned IAM role has an unexpected managed policy attachment."

    inline_policy_names="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        iam list-role-policies --role-name "$LAMBDA_ROLE_NAME" \
        --output json --no-cli-pager
    )"
    unexpected_inline_policy_count="$(
      jq \
        --arg s3_name "$LAMBDA_S3_POLICY_NAME" \
        --arg sqs_name "$LAMBDA_SQS_POLICY_NAME" \
        '[.PolicyNames[]? | select(. != $s3_name and . != $sqs_name)] | length' \
        <<<"$inline_policy_names"
    )"
    [[ "$unexpected_inline_policy_count" == "0" ]] \
      || die "Resource collision: owned IAM role has an unexpected inline policy."

    for policy_name_and_file in \
      "$LAMBDA_S3_POLICY_NAME:$GENERATED_DIR/lambda-s3-policy.json" \
      "$LAMBDA_SQS_POLICY_NAME:$GENERATED_DIR/lambda-sqs-policy.json"; do

      policy_name="${policy_name_and_file%%:*}"
      policy_file="${policy_name_and_file#*:}"

      if jq -e --arg name "$policy_name" \
        '.PolicyNames | index($name) != null' \
        <<<"$inline_policy_names" >/dev/null; then

        existing_policy="$(
          aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            iam get-role-policy \
            --role-name "$LAMBDA_ROLE_NAME" \
            --policy-name "$policy_name" \
            --output json --no-cli-pager
        )"
        existing_policy_canonical="$(
          jq -cS '.PolicyDocument' <<<"$existing_policy"
        )"
        expected_policy_canonical="$(jq -cS . "$policy_file")"
        [[ "$existing_policy_canonical" == "$expected_policy_canonical" ]] \
          || die "Resource collision: inline IAM policy '$policy_name' differs from the rendered policy."
      fi
    done
    if [[ "$adopt_role" == true ]]; then
      state_update '.resources.role.created = true'
      log "Adopted exactly matching tagged IAM role into deployment state."
    fi
  fi

  if [[ "$lambda_exists" == true ]]; then
    expected_lambda_environment="$(
      jq -ncS \
        --arg incoming "$INCOMING_PREFIX" \
        --arg compressed "$COMPRESSED_PREFIX" \
        '{COMPRESSED_PREFIX:$compressed,INCOMING_PREFIX:$incoming}'
    )"
    actual_lambda_environment="$(
      jq -cS '.Configuration.Environment.Variables // {}' <<<"$lambda_json"
    )"

    jq -e \
      --arg arn "$LAMBDA_FUNCTION_ARN" \
      --arg runtime "$LAMBDA_RUNTIME" \
      --arg handler "$LAMBDA_HANDLER" \
      --arg role "$LAMBDA_ROLE_ARN" \
      --arg architecture "$LAMBDA_ARCHITECTURE" \
      --arg code_sha256 "$LAMBDA_PACKAGE_CODE_SHA256" \
      --argjson timeout "$LAMBDA_TIMEOUT" \
      --argjson memory "$LAMBDA_MEMORY_SIZE" \
      '
        .Configuration.FunctionArn == $arn and
        .Configuration.Runtime == $runtime and
        .Configuration.Handler == $handler and
        .Configuration.Role == $role and
        .Configuration.Timeout == $timeout and
        .Configuration.MemorySize == $memory and
        .Configuration.Architectures == [$architecture] and
        .Configuration.CodeSha256 == $code_sha256
      ' <<<"$lambda_json" >/dev/null \
      || die "Resource collision: existing Lambda code or configuration differs from the recorded deployment."

    [[ "$actual_lambda_environment" == "$expected_lambda_environment" ]] \
      || die "Resource collision: existing Lambda environment differs from configured prefixes."

    if [[ "$(state_flag '.resources.lambda.created')" != true ]]; then
      state_update '.resources.lambda.created = true'
      log "Adopted exactly matching tagged Lambda function into deployment state."
    fi
  fi

  if [[ "$queue_exists" == true && "$lambda_exists" == true ]]; then
    recorded_mapping_uuid="$(
      jq -r '.resources.event_source_mapping_uuid // empty' "$STATE_FILE"
    )"

    if [[ -n "$recorded_mapping_uuid" ]]; then
      recorded_mapping_json="$(
        aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
          lambda get-event-source-mapping \
          --uuid "$recorded_mapping_uuid" \
          --output json --no-cli-pager
      )"
      validate_event_source_mapping_json "$recorded_mapping_json" \
        || die "Resource collision: recorded event-source mapping configuration differs."
    else
      existing_mappings="$(
        aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
          lambda list-event-source-mappings \
          --event-source-arn "$QUEUE_ARN" \
          --function-name "$LAMBDA_FUNCTION_NAME" \
          --output json --no-cli-pager
      )"
      mapping_count="$(jq '.EventSourceMappings | length' <<<"$existing_mappings")"

      if (( mapping_count == 1 )); then
        matching_mapping="$(jq -c '.EventSourceMappings[0]' <<<"$existing_mappings")"
        validate_event_source_mapping_json "$matching_mapping" \
          || die "Resource collision: unrecorded event-source mapping configuration differs."
        adopted_mapping_uuid="$(jq -r '.UUID // empty' <<<"$matching_mapping")"
        [[ -n "$adopted_mapping_uuid" ]] \
          || die "Existing event-source mapping returned no UUID."
        state_update \
          '.resources.event_source_mapping_uuid = $uuid |
           .steps.event_source_mapping_enabled = true' \
          --arg uuid "$adopted_mapping_uuid"
        log "Adopted exactly matching SQS-to-Lambda mapping into deployment state."
      elif (( mapping_count > 1 )); then
        die "Resource collision: multiple unrecorded event-source mappings target the queue and function."
      fi
    fi
  fi

  if [[ "$bucket_exists" == true ]]; then
    existing_notification="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api get-bucket-notification-configuration \
        --bucket "$BUCKET_NAME" \
        --output json --no-cli-pager
    )"
    existing_notification_count="$(
      jq '
        ([.QueueConfigurations[]?] | length) +
        ([.LambdaFunctionConfigurations[]?] | length) +
        ([.TopicConfigurations[]?] | length)
      ' <<<"$existing_notification"
    )"

    if (( existing_notification_count > 0 )); then
      jq -e '
        ([.LambdaFunctionConfigurations[]?] | length) == 0 and
        ([.TopicConfigurations[]?] | length) == 0
      ' <<<"$existing_notification" >/dev/null \
        || die "Resource collision: existing S3 notification configuration contains an unexpected Lambda or topic destination."
      actual_notification_canonical="$(
        jq -cS '{QueueConfigurations:(.QueueConfigurations // [])}' \
          <<<"$existing_notification"
      )"
      expected_notification_canonical="$(
        jq -cS . "$GENERATED_DIR/s3-notification.json"
      )"
      [[ "$actual_notification_canonical" == "$expected_notification_canonical" ]] \
        || die "Resource collision: existing S3 notification configuration differs from the rendered configuration."
      state_update '.steps.s3_notification_applied = true'
    fi
    if [[ "$adopt_bucket" == true ]]; then
      state_update '.resources.bucket.created = true'
      log "Adopted exactly matching tagged S3 bucket into deployment state."
    fi
  fi
fi

if [[ ! -f "$STATE_FILE" ]]; then
  jq -n \
    --arg deployment_id "$DEPLOYMENT_ID" \
    --arg deployed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg account_id "$ACCOUNT_ID" \
    --arg partition "$AWS_PARTITION" \
    --arg region "$AWS_REGION" \
    --arg profile "$AWS_PROFILE" \
    --arg project_name "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    --arg project_identifier "$PROJECT_IDENTIFIER" \
    --arg bucket_name "$BUCKET_NAME" \
    --arg bucket_arn "$BUCKET_ARN" \
    --arg queue_name "$SQS_QUEUE_NAME" \
    --arg queue_arn "$QUEUE_ARN" \
    --arg lambda_name "$LAMBDA_FUNCTION_NAME" \
    --arg lambda_arn "$LAMBDA_FUNCTION_ARN" \
    --arg role_name "$LAMBDA_ROLE_NAME" \
    --arg role_arn "$LAMBDA_ROLE_ARN" \
    --arg lambda_s3_policy_name "$LAMBDA_S3_POLICY_NAME" \
    --arg lambda_sqs_policy_name "$LAMBDA_SQS_POLICY_NAME" \
    --arg logging_policy_arn "$LOGGING_POLICY_ARN" \
    --arg deployment_configuration_fingerprint "$CONFIGURATION_FINGERPRINT" \
    --arg lambda_package_sha256 "$LAMBDA_PACKAGE_SHA256" \
    '{
      schema_version: 1,
      deployment_id: $deployment_id,
      deployment_status: "deploying",
      deployed_at: $deployed_at,
      deployment_configuration_fingerprint: $deployment_configuration_fingerprint,
      lambda_package_sha256: $lambda_package_sha256,
      identity: {
        account_id: $account_id,
        partition: $partition,
        region: $region,
        profile: $profile,
        project_name: $project_name,
        environment: $environment,
        project_identifier: $project_identifier
      },
      resources: {
        bucket: {name: $bucket_name, arn: $bucket_arn, created: false},
        queue: {name: $queue_name, url: "", arn: $queue_arn, created: false},
        lambda: {name: $lambda_name, arn: $lambda_arn, created: false},
        role: {name: $role_name, arn: $role_arn, created: false},
        policies: {
          lambda_s3_name: $lambda_s3_policy_name,
          lambda_sqs_name: $lambda_sqs_policy_name,
          logging_managed_arn: $logging_policy_arn
        },
        event_source_mapping_uuid: ""
      },
      steps: {
        bucket_configured: false,
        queue_policy_applied: false,
        role_policies_applied: false,
        lambda_ready: false,
        event_source_mapping_enabled: false,
        s3_notification_applied: false
      }
    }' \
    | write_json_atomically "$STATE_FILE"
fi

DEPLOYMENT_TAG_ID="$(jq -r '.deployment_id' "$STATE_FILE")"

if [[ "$(state_flag '.resources.bucket.created')" != true ]]; then
  log "Creating private S3 bucket: $BUCKET_NAME"

  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --output json --no-cli-pager >/dev/null
  else
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" \
      --output json --no-cli-pager >/dev/null
  fi

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api wait bucket-exists \
    --bucket "$BUCKET_NAME" \
    --no-cli-pager

  bucket_tagging="$(
    jq -nc \
      --arg deployment_id "$DEPLOYMENT_TAG_ID" \
      --arg project "$PROJECT_NAME" \
      --arg environment "$ENVIRONMENT" \
      '{TagSet:[
        {Key:"DeploymentId",Value:$deployment_id},
        {Key:"Project",Value:$project},
        {Key:"Environment",Value:$environment}
      ]}'
  )"

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api put-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --tagging "$bucket_tagging" \
    --no-cli-pager

  state_update '.resources.bucket.created = true'
fi

log "Applying private S3 ownership, public-access, and encryption controls..."

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api put-bucket-ownership-controls \
  --bucket "$BUCKET_NAME" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}' \
  --no-cli-pager

state_update '.steps.bucket_configured = true'

if [[ "$(state_flag '.resources.queue.created')" != true ]]; then
  log "Creating SQS queue: $SQS_QUEUE_NAME"

  queue_attributes="$(
    jq -nc \
      --arg visibility_timeout "$SQS_VISIBILITY_TIMEOUT" \
      '{VisibilityTimeout:$visibility_timeout}'
  )"

  queue_tags="$(
    jq -nc \
      --arg deployment_id "$DEPLOYMENT_TAG_ID" \
      --arg project "$PROJECT_NAME" \
      --arg environment "$ENVIRONMENT" \
      '{DeploymentId:$deployment_id,Project:$project,Environment:$environment}'
  )"

  queue_create_json="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      sqs create-queue \
      --queue-name "$SQS_QUEUE_NAME" \
      --attributes "$queue_attributes" \
      --tags "$queue_tags" \
      --output json --no-cli-pager
  )"

  QUEUE_URL="$(jq -r '.QueueUrl // empty' <<<"$queue_create_json")"
  [[ -n "$QUEUE_URL" ]] || die "SQS did not return a queue URL."

  queue_attributes_json="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --attribute-names QueueArn \
      --output json --no-cli-pager
  )"

  actual_queue_arn="$(jq -r '.Attributes.QueueArn // empty' <<<"$queue_attributes_json")"
  [[ "$actual_queue_arn" == "$QUEUE_ARN" ]] \
    || die "Created queue ARN does not match the deterministic queue ARN."

  state_update \
    '.resources.queue.created = true | .resources.queue.url = $queue_url' \
    --arg queue_url "$QUEUE_URL"
else
  QUEUE_URL="$(jq -r '.resources.queue.url' "$STATE_FILE")"
fi

log "Applying the S3-to-SQS resource policy..."

queue_policy="$(jq -c . "$GENERATED_DIR/sqs-resource-policy.json")"
queue_policy_attributes="$(jq -nc --arg policy "$queue_policy" '{Policy:$policy}')"

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes "$queue_policy_attributes" \
  --no-cli-pager

state_update '.steps.queue_policy_applied = true'

if [[ "$(state_flag '.resources.role.created')" != true ]]; then
  log "Creating Lambda execution role: $LAMBDA_ROLE_NAME"

  role_tags="$(
    jq -nc \
      --arg deployment_id "$DEPLOYMENT_TAG_ID" \
      --arg project "$PROJECT_NAME" \
      --arg environment "$ENVIRONMENT" \
      '[
        {Key:"DeploymentId",Value:$deployment_id},
        {Key:"Project",Value:$project},
        {Key:"Environment",Value:$environment}
      ]'
  )"

  role_json="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      iam create-role \
      --role-name "$LAMBDA_ROLE_NAME" \
      --assume-role-policy-document "file://$GENERATED_DIR/lambda-trust-policy.json" \
      --tags "$role_tags" \
      --output json --no-cli-pager
  )"

  actual_role_arn="$(jq -r '.Role.Arn // empty' <<<"$role_json")"
  [[ "$actual_role_arn" == "$LAMBDA_ROLE_ARN" ]] \
    || die "Created IAM role ARN does not match the deterministic role ARN."

  state_update '.resources.role.created = true'
fi

log "Attaching managed logging and least-privilege application permissions..."

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  iam attach-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn "$LOGGING_POLICY_ARN" \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "$LAMBDA_S3_POLICY_NAME" \
  --policy-document "file://$GENERATED_DIR/lambda-s3-policy.json" \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "$LAMBDA_SQS_POLICY_NAME" \
  --policy-document "file://$GENERATED_DIR/lambda-sqs-policy.json" \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  iam wait role-exists \
  --role-name "$LAMBDA_ROLE_NAME" \
  --no-cli-pager

state_update '.steps.role_policies_applied = true'

if [[ "$(state_flag '.resources.lambda.created')" != true ]]; then
  log "Creating Lambda function: $LAMBDA_FUNCTION_NAME"

  lambda_environment="$(
    jq -nc \
      --arg incoming_prefix "$INCOMING_PREFIX" \
      --arg compressed_prefix "$COMPRESSED_PREFIX" \
      '{Variables:{
        INCOMING_PREFIX:$incoming_prefix,
        COMPRESSED_PREFIX:$compressed_prefix
      }}'
  )"

  lambda_tags="$(
    jq -nc \
      --arg deployment_id "$DEPLOYMENT_TAG_ID" \
      --arg project "$PROJECT_NAME" \
      --arg environment "$ENVIRONMENT" \
      '{DeploymentId:$deployment_id,Project:$project,Environment:$environment}'
  )"

  create_function_error=""
  for attempt in {1..12}; do
    if lambda_create_json="$(
      aws \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        lambda create-function \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --runtime "$LAMBDA_RUNTIME" \
        --role "$LAMBDA_ROLE_ARN" \
        --handler "$LAMBDA_HANDLER" \
        --zip-file "fileb://$ZIP_FILE" \
        --timeout "$LAMBDA_TIMEOUT" \
        --memory-size "$LAMBDA_MEMORY_SIZE" \
        --environment "$lambda_environment" \
        --tags "$lambda_tags" \
        --architectures "$LAMBDA_ARCHITECTURE" \
        --output json --no-cli-pager 2>&1
    )"; then
      break
    fi

    create_function_error="$lambda_create_json"

    if (( attempt == 12 )); then
      die "Lambda creation failed after IAM propagation retries: $create_function_error"
    fi

    warn "Lambda creation is waiting for IAM propagation (attempt $attempt/12)."
    sleep 5
  done

  actual_lambda_arn="$(jq -r '.FunctionArn // empty' <<<"$lambda_create_json")"
  [[ "$actual_lambda_arn" == "$LAMBDA_FUNCTION_ARN" ]] \
    || die "Created Lambda ARN does not match the deterministic function ARN."

  state_update '.resources.lambda.created = true'
fi

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  lambda wait function-active-v2 \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --no-cli-pager

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  lambda wait function-updated-v2 \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --no-cli-pager

function_configuration="$(
  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    lambda get-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --output json --no-cli-pager
)"

[[ "$(jq -r '.State' <<<"$function_configuration")" == "Active" ]] \
  || die "Lambda function is not active."

[[ "$(jq -r '.LastUpdateStatus' <<<"$function_configuration")" == "Successful" ]] \
  || die "Lambda function's last update was not successful."

state_update '.steps.lambda_ready = true'

EVENT_SOURCE_MAPPING_UUID="$(jq -r '.resources.event_source_mapping_uuid // empty' "$STATE_FILE")"

if [[ -z "$EVENT_SOURCE_MAPPING_UUID" ]]; then
  existing_mappings="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      lambda list-event-source-mappings \
      --event-source-arn "$QUEUE_ARN" \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --output json --no-cli-pager
  )"

  [[ "$(jq '.EventSourceMappings | length' <<<"$existing_mappings")" == "0" ]] \
    || die "Resource collision: an unrecorded SQS-to-Lambda event-source mapping already exists."

  mapping_json="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      lambda create-event-source-mapping \
      --event-source-arn "$QUEUE_ARN" \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --batch-size 1 \
      --function-response-types ReportBatchItemFailures \
      --enabled \
      --output json --no-cli-pager
  )"

  EVENT_SOURCE_MAPPING_UUID="$(jq -r '.UUID // empty' <<<"$mapping_json")"
  [[ -n "$EVENT_SOURCE_MAPPING_UUID" ]] \
    || die "Lambda did not return an event-source mapping UUID."

  state_update \
    '.resources.event_source_mapping_uuid = $uuid' \
    --arg uuid "$EVENT_SOURCE_MAPPING_UUID"
fi

log "Waiting for the SQS-to-Lambda mapping to become enabled..."

mapping_enabled=false
for attempt in {1..60}; do
  mapping_state="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      lambda get-event-source-mapping \
      --uuid "$EVENT_SOURCE_MAPPING_UUID" \
      --query State --output text --no-cli-pager
  )"

  if [[ "$mapping_state" == "Enabled" ]]; then
    mapping_enabled=true
    break
  fi

  [[ "$mapping_state" != "Failed" ]] \
    || die "SQS-to-Lambda event-source mapping entered Failed state."

  sleep 5
done

[[ "$mapping_enabled" == true ]] \
  || die "Timed out waiting for the event-source mapping to become enabled."

state_update '.steps.event_source_mapping_enabled = true'

if [[ "$(state_flag '.steps.s3_notification_applied')" != true ]]; then
  log "Applying S3 notification after the queue policy is active..."
  sleep 5

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration "file://$GENERATED_DIR/s3-notification.json" \
    --no-cli-pager
fi

state_update \
  '.steps.s3_notification_applied = true |
   .deployment_status = "complete" |
   .completed_at = $completed_at' \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Deployment complete."
log "Project/environment: $PROJECT_IDENTIFIER"
log "Bucket: $BUCKET_NAME"
log "Queue URL: $QUEUE_URL"
log "Lambda function: $LAMBDA_FUNCTION_NAME"
log "IAM role: $LAMBDA_ROLE_NAME"
log "Event-source mapping: $EVENT_SOURCE_MAPPING_UUID"
log "State: $STATE_FILE"
log "Next: run ./infrastructure/validate.sh after Phase 4 validation is implemented."
