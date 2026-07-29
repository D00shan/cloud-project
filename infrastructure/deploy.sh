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

for command_name in aws jq npm zip unzip; do
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
    [[ "$(state_flag '.resources.bucket.created')" == true ]] \
      || die "Resource collision: bucket exists but state does not record its creation: $BUCKET_NAME."

    bucket_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api get-bucket-tagging --bucket "$BUCKET_NAME" \
        --output json --no-cli-pager
    )"

    verify_tag_array "$bucket_tags" '.TagSet' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded bucket ownership tags do not match deployment state: $BUCKET_NAME"
  elif [[ "$(state_flag '.resources.bucket.created')" == true ]]; then
    die "State records bucket creation, but the bucket no longer exists: $BUCKET_NAME"
  fi

  if [[ "$queue_exists" == true ]]; then
    [[ "$(state_flag '.resources.queue.created')" == true ]] \
      || die "Resource collision: queue exists but state does not record its creation: $SQS_QUEUE_NAME."

    recorded_queue_url="$(jq -r '.resources.queue.url // empty' "$STATE_FILE")"
    actual_queue_url="$(jq -r '.QueueUrl // empty' <<<"$queue_json")"
    [[ "$actual_queue_url" == "$recorded_queue_url" ]] \
      || die "Recorded SQS queue URL does not match the existing queue."

    queue_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        sqs list-queue-tags --queue-url "$actual_queue_url" \
        --output json --no-cli-pager
    )"

    verify_tag_map "$queue_tags" '.Tags' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded queue ownership tags do not match deployment state: $SQS_QUEUE_NAME"
  elif [[ "$(state_flag '.resources.queue.created')" == true ]]; then
    die "State records queue creation, but the queue no longer exists: $SQS_QUEUE_NAME"
  fi

  if [[ "$role_exists" == true ]]; then
    [[ "$(state_flag '.resources.role.created')" == true ]] \
      || die "Resource collision: role exists but state does not record its creation: $LAMBDA_ROLE_NAME."

    role_tags="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        iam list-role-tags --role-name "$LAMBDA_ROLE_NAME" \
        --output json --no-cli-pager
    )"

    verify_tag_array "$role_tags" '.Tags' "$DEPLOYMENT_TAG_ID" \
      || die "Recorded role ownership tags do not match deployment state: $LAMBDA_ROLE_NAME"
  elif [[ "$(state_flag '.resources.role.created')" == true ]]; then
    die "State records role creation, but the role no longer exists: $LAMBDA_ROLE_NAME"
  fi

  if [[ "$lambda_exists" == true ]]; then
    [[ "$(state_flag '.resources.lambda.created')" == true ]] \
      || die "Resource collision: function exists but state does not record its creation: $LAMBDA_FUNCTION_NAME."

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
    '{
      schema_version: 1,
      deployment_id: $deployment_id,
      deployment_status: "deploying",
      deployed_at: $deployed_at,
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
        --handler index.handler \
        --zip-file "fileb://$ZIP_FILE" \
        --timeout "$LAMBDA_TIMEOUT" \
        --memory-size "$LAMBDA_MEMORY_SIZE" \
        --environment "$lambda_environment" \
        --tags "$lambda_tags" \
        --architectures x86_64 \
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

log "Applying S3 notification after the queue policy is active..."
sleep 5

aws \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration "file://$GENERATED_DIR/s3-notification.json" \
  --no-cli-pager

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
