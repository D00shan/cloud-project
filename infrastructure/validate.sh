#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/state/deployment.json"
GENERATED_DIR="$SCRIPT_DIR/build/generated-config"
KEEP_ARTIFACTS=false

while (( $# > 0 )); do
  case "$1" in
    --config)
      (( $# >= 2 )) || die "--config requires a file path."
      CONFIG_FILE="$2"
      shift 2
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=true
      shift
      ;;
    *)
      die "Unsupported argument: $1. Use --config PATH and optionally --keep-artifacts."
      ;;
  esac
done

for command_name in aws jq gzip gunzip cmp mktemp dd date sleep; do
  require_command "$command_name"
done

[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

required_values=(
  AWS_PROFILE AWS_REGION PROJECT_NAME ENVIRONMENT BUCKET_NAME_PREFIX
  INCOMING_PREFIX COMPRESSED_PREFIX SQS_QUEUE_NAME SQS_VISIBILITY_TIMEOUT
  LAMBDA_FUNCTION_NAME LAMBDA_ROLE_NAME LAMBDA_RUNTIME
  LAMBDA_MEMORY_SIZE LAMBDA_TIMEOUT
)
for variable_name in "${required_values[@]}"; do
  require_config_value "$variable_name"
done

validate_aws_region "$AWS_REGION"
validate_object_prefixes "$INCOMING_PREFIX" "$COMPRESSED_PREFIX"
export AWS_PAGER=""

aws_json() {
  local description="$1"
  shift
  local output
  if ! output="$(aws "$@" 2>&1)"; then
    die "$description failed. AWS response: $output"
  fi
  jq empty <<<"$output" >/dev/null 2>&1 \
    || die "$description returned malformed JSON."
  printf '%s' "$output"
}

IDENTITY_JSON="$(
  aws_json "AWS authentication" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    sts get-caller-identity --output json --no-cli-pager
)"
ACCOUNT_ID="$(jq -r '.Account // empty' <<<"$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn // empty' <<<"$IDENTITY_JSON")"
validate_account_id "$ACCOUNT_ID"

IFS=: read -r arn_label AWS_PARTITION caller_service caller_region \
  caller_account caller_resource <<<"$CALLER_ARN"
[[ "$arn_label" == arn &&
   ( "$caller_service" == iam || "$caller_service" == sts ) &&
   -z "$caller_region" &&
   "$caller_account" == "$ACCOUNT_ID" &&
   -n "$caller_resource" ]] \
  || die "AWS returned an inconsistent caller identity: $CALLER_ARN"
validate_aws_partition "$AWS_PARTITION"

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

validate_deployment_state \
  "$STATE_FILE" \
  "$ACCOUNT_ID" "$AWS_PARTITION" "$AWS_REGION" "$AWS_PROFILE" \
  "$PROJECT_NAME" "$ENVIRONMENT" \
  "$BUCKET_NAME" "$BUCKET_ARN" \
  "$SQS_QUEUE_NAME" "$QUEUE_ARN" \
  "$LAMBDA_FUNCTION_NAME" "$LAMBDA_FUNCTION_ARN" \
  "$LAMBDA_ROLE_NAME" "$LAMBDA_ROLE_ARN" \
  "$LAMBDA_S3_POLICY_NAME" "$LAMBDA_SQS_POLICY_NAME"

jq -e '
  .deployment_status == "complete" and
  .resources.bucket.created == true and
  .resources.queue.created == true and
  .resources.lambda.created == true and
  .resources.role.created == true and
  (.resources.queue.url | type == "string" and length > 0) and
  (.resources.event_source_mapping_uuid | type == "string" and length > 0) and
  (.steps | to_entries | all(.value == true))
' "$STATE_FILE" >/dev/null \
  || die "Deployment state is incomplete; validation requires a complete deployment."

DEPLOYMENT_ID="$(jq -r '.deployment_id' "$STATE_FILE")"
QUEUE_URL="$(jq -r '.resources.queue.url' "$STATE_FILE")"
MAPPING_UUID="$(jq -r '.resources.event_source_mapping_uuid' "$STATE_FILE")"

for generated_file in \
  lambda-trust-policy.json lambda-s3-policy.json lambda-sqs-policy.json \
  sqs-resource-policy.json s3-notification.json; do
  validate_json_file "$GENERATED_DIR/$generated_file" "$BUCKET_ARN" "$QUEUE_ARN"
done

tag_array_matches() {
  local json="$1"
  local path="$2"
  jq -e \
    --arg deployment_id "$DEPLOYMENT_ID" \
    --arg project "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    "$path |
      (map(select(.Key == \"DeploymentId\"))[0].Value == \$deployment_id) and
      (map(select(.Key == \"Project\"))[0].Value == \$project) and
      (map(select(.Key == \"Environment\"))[0].Value == \$environment)" \
    <<<"$json" >/dev/null
}

tag_map_matches() {
  local json="$1"
  local path="$2"
  jq -e \
    --arg deployment_id "$DEPLOYMENT_ID" \
    --arg project "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    "$path.DeploymentId == \$deployment_id and
     $path.Project == \$project and
     $path.Environment == \$environment" \
    <<<"$json" >/dev/null
}

canonical_json_file() {
  jq -cS . "$1"
}

OBJECT_LOOKUP_ERROR=""
object_presence() {
  local key="$1"
  OBJECT_LOOKUP_ERROR=""
  if OBJECT_LOOKUP_ERROR="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api head-object --bucket "$BUCKET_NAME" --key "$key" \
      --no-cli-pager 2>&1
  )"; then
    return 0
  fi
  if grep -Eq '(^|[^0-9])404([^0-9]|$)|NoSuchKey|Not Found' \
    <<<"$OBJECT_LOOKUP_ERROR"; then
    return 1
  fi
  return 2
}

log "Verifying deployed security and configuration..."

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api head-bucket --bucket "$BUCKET_NAME" --no-cli-pager >/dev/null \
  || die "Configured S3 bucket is missing or inaccessible: $BUCKET_NAME"
bucket_tags="$(aws_json "S3 bucket tag lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api get-bucket-tagging \
  --bucket "$BUCKET_NAME" --output json --no-cli-pager)"
tag_array_matches "$bucket_tags" '.TagSet' \
  || die "S3 bucket ownership tags do not match deployment state."

public_block="$(aws_json "S3 public-access-block lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api get-public-access-block --bucket "$BUCKET_NAME" \
  --output json --no-cli-pager)"
jq -e '
  .PublicAccessBlockConfiguration |
  .BlockPublicAcls and .IgnorePublicAcls and
  .BlockPublicPolicy and .RestrictPublicBuckets
' <<<"$public_block" >/dev/null \
  || die "S3 public-access block is not fully enabled."

ownership="$(aws_json "S3 ownership-controls lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api get-bucket-ownership-controls --bucket "$BUCKET_NAME" \
  --output json --no-cli-pager)"
jq -e '.OwnershipControls.Rules == [{ObjectOwnership:"BucketOwnerEnforced"}]' \
  <<<"$ownership" >/dev/null \
  || die "S3 object ownership is not BucketOwnerEnforced."

encryption="$(aws_json "S3 encryption lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api get-bucket-encryption --bucket "$BUCKET_NAME" \
  --output json --no-cli-pager)"
jq -e '
  [.ServerSideEncryptionConfiguration.Rules[]?
   .ApplyServerSideEncryptionByDefault.SSEAlgorithm] |
  length > 0 and all(. == "AES256" or . == "aws:kms")
' <<<"$encryption" >/dev/null \
  || die "S3 default server-side encryption is missing or invalid."

policy_status_output=""
if policy_status_output="$(
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api get-bucket-policy-status --bucket "$BUCKET_NAME" \
    --output json --no-cli-pager 2>&1
)"; then
  jq -e '.PolicyStatus.IsPublic == false' <<<"$policy_status_output" >/dev/null \
    || die "AWS reports that the S3 bucket policy is public."
elif ! grep -Eq 'NoSuchBucketPolicy' <<<"$policy_status_output"; then
  die "S3 bucket-policy status lookup failed. AWS response: $policy_status_output"
fi

notification="$(aws_json "S3 notification lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  s3api get-bucket-notification-configuration --bucket "$BUCKET_NAME" \
  --output json --no-cli-pager)"
jq -e \
  --arg queue_arn "$QUEUE_ARN" \
  --arg incoming "$INCOMING_PREFIX" \
  --arg compressed "$COMPRESSED_PREFIX" '
    (.QueueConfigurations | length) == 1 and
    ((.LambdaFunctionConfigurations // []) | length) == 0 and
    ((.TopicConfigurations // []) | length) == 0 and
    .QueueConfigurations[0].QueueArn == $queue_arn and
    .QueueConfigurations[0].Events == ["s3:ObjectCreated:*"] and
    .QueueConfigurations[0].Filter.Key.FilterRules ==
      [{Name:"prefix",Value:$incoming}] and
    (.QueueConfigurations[0].Filter.Key.FilterRules |
      all(.Value != $compressed))
  ' <<<"$notification" >/dev/null \
  || die "S3 notification does not exactly match the deployed queue and incoming prefix."

queue_lookup="$(aws_json "SQS queue lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" sqs get-queue-url \
  --queue-name "$SQS_QUEUE_NAME" --output json --no-cli-pager)"
[[ "$(jq -r '.QueueUrl // empty' <<<"$queue_lookup")" == "$QUEUE_URL" ]] \
  || die "SQS queue URL does not match deployment state."
queue_attributes="$(aws_json "SQS attribute lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" --attribute-names All --output json --no-cli-pager)"
jq -e \
  --arg arn "$QUEUE_ARN" \
  --arg timeout "$SQS_VISIBILITY_TIMEOUT" '
    .Attributes.QueueArn == $arn and
    .Attributes.VisibilityTimeout == $timeout and
    (.Attributes.Policy | type == "string" and length > 0)
  ' <<<"$queue_attributes" >/dev/null \
  || die "SQS ARN, visibility timeout, or resource policy is incorrect."
actual_queue_policy="$(jq -r '.Attributes.Policy' <<<"$queue_attributes" | jq -cS .)"
expected_queue_policy="$(canonical_json_file "$GENERATED_DIR/sqs-resource-policy.json")"
[[ "$actual_queue_policy" == "$expected_queue_policy" ]] \
  || die "SQS resource policy differs from the rendered policy."
queue_tags="$(aws_json "SQS tag lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" sqs list-queue-tags \
  --queue-url "$QUEUE_URL" --output json --no-cli-pager)"
tag_map_matches "$queue_tags" '.Tags' \
  || die "SQS ownership tags do not match deployment state."

role_json="$(aws_json "IAM role lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" iam get-role \
  --role-name "$LAMBDA_ROLE_NAME" --output json --no-cli-pager)"
jq -e --arg arn "$LAMBDA_ROLE_ARN" \
  '.Role.Arn == $arn' <<<"$role_json" >/dev/null \
  || die "IAM role ARN does not match deployment state."
actual_trust="$(jq -cS '.Role.AssumeRolePolicyDocument' <<<"$role_json")"
[[ "$actual_trust" == "$(canonical_json_file "$GENERATED_DIR/lambda-trust-policy.json")" ]] \
  || die "IAM trust policy differs from the rendered Lambda trust policy."
role_tags="$(aws_json "IAM role tag lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" iam list-role-tags \
  --role-name "$LAMBDA_ROLE_NAME" --output json --no-cli-pager)"
tag_array_matches "$role_tags" '.Tags' \
  || die "IAM role ownership tags do not match deployment state."
attached="$(aws_json "IAM managed-policy lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" iam list-attached-role-policies \
  --role-name "$LAMBDA_ROLE_NAME" --output json --no-cli-pager)"
jq -e --arg expected "$LOGGING_POLICY_ARN" '
  [.AttachedPolicies[].PolicyArn] == [$expected]
' <<<"$attached" >/dev/null \
  || die "IAM role has missing or unexpected attached managed policies."
inline_names="$(aws_json "IAM inline-policy list" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" iam list-role-policies \
  --role-name "$LAMBDA_ROLE_NAME" --output json --no-cli-pager)"
jq -e \
  --arg s3 "$LAMBDA_S3_POLICY_NAME" \
  --arg sqs "$LAMBDA_SQS_POLICY_NAME" '
    (.PolicyNames | sort) == ([$s3,$sqs] | sort)
  ' <<<"$inline_names" >/dev/null \
  || die "IAM role has missing or unexpected inline policies."
for policy_spec in \
  "$LAMBDA_S3_POLICY_NAME:$GENERATED_DIR/lambda-s3-policy.json" \
  "$LAMBDA_SQS_POLICY_NAME:$GENERATED_DIR/lambda-sqs-policy.json"; do
  policy_name="${policy_spec%%:*}"
  policy_file="${policy_spec#*:}"
  policy_json="$(aws_json "IAM inline policy '$policy_name' lookup" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" iam get-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" --policy-name "$policy_name" \
    --output json --no-cli-pager)"
  [[ "$(jq -cS '.PolicyDocument' <<<"$policy_json")" == \
     "$(canonical_json_file "$policy_file")" ]] \
    || die "IAM inline policy '$policy_name' differs from the rendered policy."
done

lambda_json="$(aws_json "Lambda function lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" lambda get-function \
  --function-name "$LAMBDA_FUNCTION_NAME" --output json --no-cli-pager)"
jq -e \
  --arg arn "$LAMBDA_FUNCTION_ARN" \
  --arg role "$LAMBDA_ROLE_ARN" \
  --arg handler "index.handler" \
  --arg runtime "$LAMBDA_RUNTIME" \
  --arg incoming "$INCOMING_PREFIX" \
  --arg compressed "$COMPRESSED_PREFIX" \
  --argjson timeout "$LAMBDA_TIMEOUT" \
  --argjson memory "$LAMBDA_MEMORY_SIZE" '
    .Configuration.FunctionArn == $arn and
    .Configuration.Role == $role and
    .Configuration.Handler == $handler and
    .Configuration.Runtime == $runtime and
    .Configuration.Timeout == $timeout and
    .Configuration.MemorySize == $memory and
    .Configuration.State == "Active" and
    (.Configuration.LastUpdateStatus // "Successful") == "Successful" and
    .Configuration.Environment.Variables.INCOMING_PREFIX == $incoming and
    .Configuration.Environment.Variables.COMPRESSED_PREFIX == $compressed
  ' <<<"$lambda_json" >/dev/null \
  || die "Lambda configuration differs from deployment state or config."
lambda_tags="$(aws_json "Lambda tag lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" lambda list-tags \
  --resource "$LAMBDA_FUNCTION_ARN" --output json --no-cli-pager)"
tag_map_matches "$lambda_tags" '.Tags' \
  || die "Lambda ownership tags do not match deployment state."

mapping="$(aws_json "Event-source mapping lookup" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  lambda get-event-source-mapping --uuid "$MAPPING_UUID" \
  --output json --no-cli-pager)"
jq -e \
  --arg queue "$QUEUE_ARN" \
  --arg function "$LAMBDA_FUNCTION_ARN" '
    .UUID != null and
    .EventSourceArn == $queue and
    (.FunctionArn == $function or .FunctionArn == ($function + ":$LATEST")) and
    .State == "Enabled" and
    .BatchSize == 1 and
    (.MaximumBatchingWindowInSeconds // 0) == 0 and
    .FunctionResponseTypes == ["ReportBatchItemFailures"] and
    ((.FilterCriteria.Filters // []) | length) == 0 and
    (.DestinationConfig // {}) == {} and
    (.ScalingConfig // {}) == {} and
    (.ProvisionedPollerConfig // {}) == {} and
    (.KMSKeyArn // "") == "" and
    (.MetricsConfig // {}) == {} and
    ((.SourceAccessConfigurations // []) | length) == 0 and
    (.AmazonManagedKafkaEventSourceConfig // {}) == {} and
    (.SelfManagedKafkaEventSourceConfig // {}) == {} and
    (.SelfManagedEventSource // {}) == {} and
    (.DocumentDBEventSourceConfig // {}) == {} and
    (.RabbitMQEventSourceConfig // {}) == {}
  ' <<<"$mapping" >/dev/null \
  || die "Event-source mapping is missing, disabled, or has unexpected configuration."

security_result="PASS"
START_EPOCH_MS="$(( $(date +%s) * 1000 ))"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
VALIDATION_ROOT="phase4-validation/$RUN_ID"
LOCAL_DIR="$(mktemp -d)"
declare -a SOURCE_KEYS=()
declare -a DESTINATION_KEYS=()

cleanup() {
  local exit_status=$?
  local cleanup_status="$exit_status"
  trap - EXIT
  if [[ "$KEEP_ARTIFACTS" == true ]]; then
    for key in "${DESTINATION_KEYS[@]:-}"; do
      [[ -n "$key" ]] && printf 'Retained: s3://%s/%s\n' "$BUCKET_NAME" "$key"
    done
  else
    for key in "${DESTINATION_KEYS[@]:-}"; do
      [[ -n "$key" ]] || continue
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api delete-object --bucket "$BUCKET_NAME" --key "$key" \
        --no-cli-pager >/dev/null 2>&1 || {
          warn "Could not remove validation artifact: s3://$BUCKET_NAME/$key"
          cleanup_status=1
          continue
        }
      if object_presence "$key"; then
        warn "Validation artifact still exists after cleanup: s3://$BUCKET_NAME/$key"
        cleanup_status=1
      else
        lookup_status=$?
        if (( lookup_status != 1 )); then
          warn "Could not verify artifact cleanup: s3://$BUCKET_NAME/$key ($OBJECT_LOOKUP_ERROR)"
          cleanup_status=1
        fi
      fi
    done
  fi
  rm -rf -- "$LOCAL_DIR"
  exit "$cleanup_status"
}
trap cleanup EXIT

printf 'Portable validation text: %s\n' "$RUN_ID" >"$LOCAL_DIR/utf8.txt"
dd if=/dev/urandom of="$LOCAL_DIR/binary.bin" bs=1024 count=4 status=none
printf 'Filename with spaces: %s\n' "$RUN_ID" >"$LOCAL_DIR/file with spaces.txt"

case_names=("utf8.txt" "binary.bin" "file with spaces.txt")
passed_cases=0
for case_name in "${case_names[@]}"; do
  relative_path="$VALIDATION_ROOT/$case_name"
  source_key="$INCOMING_PREFIX$relative_path"
  destination_key="$COMPRESSED_PREFIX$relative_path.gz"
  SOURCE_KEYS+=("$source_key")
  DESTINATION_KEYS+=("$destination_key")
  log "Uploading validation case: $case_name"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3 cp "$LOCAL_DIR/$case_name" "s3://$BUCKET_NAME/$source_key" \
    --no-cli-pager >/dev/null \
    || die "Could not upload validation case: $case_name"

  output_ready=false
  for attempt in {1..60}; do
    if object_presence "$destination_key"; then
      output_ready=true
      break
    else
      lookup_status=$?
      (( lookup_status == 1 )) \
        || die "Destination lookup failed ambiguously for '$destination_key'. AWS response: $OBJECT_LOOKUP_ERROR"
    fi
    (( attempt % 10 == 0 )) && log "Still waiting for compressed output: $case_name ($attempt/60)"
    sleep 5
  done
  [[ "$output_ready" == true ]] \
    || die "Timed out waiting for compressed output: s3://$BUCKET_NAME/$destination_key"

  if object_presence "$source_key"; then
    die "Lambda did not delete source object: s3://$BUCKET_NAME/$source_key"
  else
    lookup_status=$?
    (( lookup_status == 1 )) \
      || die "Source lookup failed ambiguously for '$source_key'. AWS response: $OBJECT_LOOKUP_ERROR"
  fi

  downloaded="$LOCAL_DIR/$case_name.gz"
  decompressed="$LOCAL_DIR/$case_name.decoded"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3 cp "s3://$BUCKET_NAME/$destination_key" "$downloaded" \
    --no-cli-pager >/dev/null \
    || die "Could not download compressed output: $destination_key"
  gzip -t "$downloaded" || die "Compressed output is not valid gzip: $destination_key"
  gunzip -c "$downloaded" >"$decompressed" \
    || die "Could not decompress output: $destination_key"
  cmp "$LOCAL_DIR/$case_name" "$decompressed" \
    || die "Decompressed content differs from source: $case_name"
  passed_cases=$((passed_cases + 1))
  log "Validation case passed: $case_name"
done

queue_healthy=false
consecutive_empty=0
for attempt in {1..60}; do
  health="$(aws_json "SQS health lookup" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
      ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
    --output json --no-cli-pager)"
  if jq -e '
    (.Attributes.ApproximateNumberOfMessages | tonumber) == 0 and
    (.Attributes.ApproximateNumberOfMessagesNotVisible | tonumber) == 0 and
    (.Attributes.ApproximateNumberOfMessagesDelayed | tonumber) == 0
  ' <<<"$health" >/dev/null; then
    consecutive_empty=$((consecutive_empty + 1))
    if (( consecutive_empty >= 2 )); then
      queue_healthy=true
      break
    fi
  else
    consecutive_empty=0
  fi
  sleep 5
done
[[ "$queue_healthy" == true ]] \
  || die "SQS queue did not remain empty for two consecutive checks."

logs_healthy=false
for attempt in {1..60}; do
  log_output=""
  if ! log_output="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      logs filter-log-events \
      --log-group-name "/aws/lambda/$LAMBDA_FUNCTION_NAME" \
      --start-time "$START_EPOCH_MS" \
      --filter-pattern "\"$RUN_ID\"" \
      --output json --no-cli-pager 2>&1
  )"; then
    if grep -Eq 'AccessDenied|not authorized' <<<"$log_output"; then
      die "CloudWatch Logs validation requires logs:FilterLogEvents permission. AWS response: $log_output"
    fi
    die "CloudWatch Logs lookup failed. AWS response: $log_output"
  fi
  jq empty <<<"$log_output" >/dev/null 2>&1 \
    || die "CloudWatch Logs lookup returned malformed JSON."
  messages="$(jq -r '[.events[]?.message] | join("\n")' <<<"$log_output")"
  if grep -Fq "$RUN_ID" <<<"$messages" &&
     grep -Fq 'File compression invocation completed' <<<"$messages"; then
    if grep -Eq 'SQS message processing failed|Unhandled|Runtime\\.(ExitError|Unknown)' <<<"$messages"; then
      die "CloudWatch Logs contain a processing or runtime failure for run $RUN_ID."
    fi
    logs_healthy=true
    break
  fi
  sleep 5
done
[[ "$logs_healthy" == true ]] \
  || die "Timed out waiting for successful CloudWatch logs for run $RUN_ID."

if [[ "$KEEP_ARTIFACTS" == false ]]; then
  for source_key in "${SOURCE_KEYS[@]}"; do
    if object_presence "$source_key"; then
      die "A source validation object unexpectedly remains: $source_key"
    else
      lookup_status=$?
      (( lookup_status == 1 )) \
        || die "Final source lookup failed ambiguously for '$source_key'. AWS response: $OBJECT_LOOKUP_ERROR"
    fi
  done
fi

printf '%s\n' \
  "Validation summary:" \
  "  Project/environment: $PROJECT_IDENTIFIER" \
  "  Account/region: $ACCOUNT_ID / $AWS_REGION" \
  "  Bucket: $BUCKET_NAME" \
  "  Queue: $QUEUE_URL" \
  "  Lambda: $LAMBDA_FUNCTION_NAME" \
  "  Test cases passed: $passed_cases/${#case_names[@]}" \
  "  Source deletion: PASS" \
  "  Gzip and byte comparison: PASS" \
  "  SQS health: PASS" \
  "  CloudWatch logs: PASS" \
  "  Security/configuration: $security_result"
