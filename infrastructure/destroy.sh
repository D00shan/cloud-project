#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/state/deployment.json"
NON_INTERACTIVE_CONFIRMATION=""

while (( $# > 0 )); do
  case "$1" in
    --config)
      (( $# >= 2 )) || die "--config requires a file path."
      CONFIG_FILE="$2"
      shift 2
      ;;
    --yes)
      (( $# >= 2 )) || die "--yes requires the exact project/environment identifier."
      NON_INTERACTIVE_CONFIRMATION="$2"
      shift 2
      ;;
    *)
      die "Unsupported argument: $1. Use --config PATH and optionally --yes PROJECT/ENVIRONMENT."
      ;;
  esac
done

[[ -f "$STATE_FILE" ]] \
  || die "Deployment state is missing: $STATE_FILE. Refusing to infer destructive targets."

[[ -f "$CONFIG_FILE" ]] \
  || die "Config file not found: $CONFIG_FILE"

set -a

# shellcheck disable=SC1090
source "$CONFIG_FILE"

set +a

for variable_name in \
  AWS_PROFILE AWS_REGION PROJECT_NAME ENVIRONMENT BUCKET_NAME_PREFIX \
  INCOMING_PREFIX COMPRESSED_PREFIX SQS_QUEUE_NAME \
  LAMBDA_FUNCTION_NAME LAMBDA_ROLE_NAME; do

  require_config_value "$variable_name"
done

for command_name in aws jq base64; do
  require_command "$command_name"
done

export AWS_PAGER=""

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

DEPLOYMENT_ID="$(jq -r '.deployment_id' "$STATE_FILE")"
QUEUE_URL="$(jq -r '.resources.queue.url // empty' "$STATE_FILE")"
EVENT_SOURCE_MAPPING_UUID="$(jq -r '.resources.event_source_mapping_uuid // empty' "$STATE_FILE")"
LOGGING_POLICY_ARN="$(jq -r '.resources.policies.logging_managed_arn // empty' "$STATE_FILE")"

[[ "$LOGGING_POLICY_ARN" == "arn:$AWS_PARTITION:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" ]] \
  || die "State contains an unexpected managed logging policy ARN."

verify_tag_array() {
  local json="$1"
  local tags_path="$2"

  jq -e \
    --arg deployment_id "$DEPLOYMENT_ID" \
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

  jq -e \
    --arg deployment_id "$DEPLOYMENT_ID" \
    --arg project "$PROJECT_NAME" \
    --arg environment "$ENVIRONMENT" \
    "
      $tags_path.DeploymentId == \$deployment_id and
      $tags_path.Project == \$project and
      $tags_path.Environment == \$environment
    " \
    <<<"$json" >/dev/null
}

log "Verifying ownership tags before showing any destructive plan..."

if [[ "$(jq -r '.resources.bucket.created' "$STATE_FILE")" == true ]]; then
  bucket_tags="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api get-bucket-tagging --bucket "$BUCKET_NAME" \
      --output json --no-cli-pager
  )"
  verify_tag_array "$bucket_tags" '.TagSet' \
    || die "S3 bucket ownership tags do not match deployment state: $BUCKET_NAME"
fi

if [[ "$(jq -r '.resources.queue.created' "$STATE_FILE")" == true ]]; then
  [[ -n "$QUEUE_URL" ]] || die "State does not contain the recorded queue URL."

  queue_lookup_json="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" \
      --output json --no-cli-pager
  )"

  actual_queue_url="$(jq -r '.QueueUrl // empty' <<<"$queue_lookup_json")"
  [[ "$actual_queue_url" == "$QUEUE_URL" ]] \
    || die "Recorded SQS queue URL does not match the configured queue name."

  queue_tags="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      sqs list-queue-tags --queue-url "$QUEUE_URL" \
      --output json --no-cli-pager
  )"
  verify_tag_map "$queue_tags" '.Tags' \
    || die "SQS queue ownership tags do not match deployment state: $SQS_QUEUE_NAME"
fi

if [[ "$(jq -r '.resources.role.created' "$STATE_FILE")" == true ]]; then
  role_tags="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      iam list-role-tags --role-name "$LAMBDA_ROLE_NAME" \
      --output json --no-cli-pager
  )"
  verify_tag_array "$role_tags" '.Tags' \
    || die "IAM role ownership tags do not match deployment state: $LAMBDA_ROLE_NAME"
fi

if [[ "$(jq -r '.resources.lambda.created' "$STATE_FILE")" == true ]]; then
  function_tags="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      lambda list-tags --resource "$LAMBDA_FUNCTION_ARN" \
      --output json --no-cli-pager
  )"
  verify_tag_map "$function_tags" '.Tags' \
    || die "Lambda ownership tags do not match deployment state: $LAMBDA_FUNCTION_NAME"
fi

if [[ -n "$EVENT_SOURCE_MAPPING_UUID" ]]; then
  mapping_json="$(
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      lambda get-event-source-mapping --uuid "$EVENT_SOURCE_MAPPING_UUID" \
      --output json --no-cli-pager
  )"

  jq -e \
    --arg queue_arn "$QUEUE_ARN" \
    --arg function_arn "$LAMBDA_FUNCTION_ARN" \
    '.EventSourceArn == $queue_arn and
     (.FunctionArn == $function_arn or .FunctionArn == ($function_arn + ":$LATEST"))' \
    <<<"$mapping_json" >/dev/null \
    || die "Event-source mapping does not target the recorded queue and function."
fi

printf '%s\n' \
  "Destruction plan for $PROJECT_IDENTIFIER:" \
  "  1. Disable/delete event-source mapping: ${EVENT_SOURCE_MAPPING_UUID:-<none>}" \
  "  2. Remove S3 notification from: $BUCKET_NAME" \
  "  3. Delete Lambda function: $LAMBDA_FUNCTION_NAME" \
  "  4. Remove IAM policies and role: $LAMBDA_ROLE_NAME" \
  "  5. Delete SQS queue: $SQS_QUEUE_NAME" \
  "  6. Empty and delete S3 bucket: $BUCKET_NAME" \
  "  7. Remove state only after every prior step succeeds: $STATE_FILE"

if [[ -n "$NON_INTERACTIVE_CONFIRMATION" ]]; then
  validate_typed_confirmation \
    "$NON_INTERACTIVE_CONFIRMATION" \
    "$PROJECT_IDENTIFIER"
else
  printf 'Type %s to confirm destruction: ' "$PROJECT_IDENTIFIER"
  IFS= read -r typed_confirmation
  validate_typed_confirmation \
    "$typed_confirmation" \
    "$PROJECT_IDENTIFIER"
fi

update_destroy_state() {
  local jq_filter="$1"
  shift
  update_json_file_atomically "$STATE_FILE" "$jq_filter" "$@"
}

iam_cleanup_allow_missing() {
  local description="$1"
  shift
  local command_output

  if command_output="$(aws "$@" 2>&1)"; then
    log "$description"
    return 0
  fi

  if grep -Eq 'NoSuchEntity' <<<"$command_output"; then
    log "$description (already absent)"
    return 0
  fi

  die "$description failed. AWS response: $command_output"
}

update_destroy_state \
  '.deployment_status = "destroying" |
   .destruction_started_at = $started_at' \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

destroy_failure() {
  local exit_code=$?
  warn "Destruction stopped before completion. State was preserved at: $STATE_FILE"
  warn "Inspect remaining resources with the configured profile '$AWS_PROFILE' and region '$AWS_REGION', then rerun destroy.sh."
  exit "$exit_code"
}

trap destroy_failure ERR

if [[ -n "$EVENT_SOURCE_MAPPING_UUID" ]]; then
  log "Disabling event-source mapping: $EVENT_SOURCE_MAPPING_UUID"
  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    lambda update-event-source-mapping \
    --uuid "$EVENT_SOURCE_MAPPING_UUID" \
    --no-enabled \
    --output json --no-cli-pager >/dev/null

  for attempt in {1..60}; do
    mapping_state="$(
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        lambda get-event-source-mapping \
        --uuid "$EVENT_SOURCE_MAPPING_UUID" \
        --query State --output text --no-cli-pager
    )"
    [[ "$mapping_state" == "Disabled" ]] && break
    (( attempt < 60 )) || die "Timed out waiting for the event-source mapping to disable."
    sleep 5
  done

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    lambda delete-event-source-mapping \
    --uuid "$EVENT_SOURCE_MAPPING_UUID" \
    --output json --no-cli-pager >/dev/null

  update_destroy_state \
    '.resources.event_source_mapping_uuid = "" |
     .steps.event_source_mapping_enabled = false'
fi

if [[ "$(jq -r '.resources.bucket.created' "$STATE_FILE")" == true ]]; then
  log "Removing S3 notification configuration..."
  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration '{}' \
    --no-cli-pager

  update_destroy_state '.steps.s3_notification_applied = false'
fi

if [[ "$(jq -r '.resources.lambda.created' "$STATE_FILE")" == true ]]; then
  log "Deleting Lambda function: $LAMBDA_FUNCTION_NAME"
  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    lambda delete-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --no-cli-pager

  update_destroy_state \
    '.resources.lambda.created = false |
     .steps.lambda_ready = false'
fi

if [[ "$(jq -r '.resources.role.created' "$STATE_FILE")" == true ]]; then
  log "Removing expected Lambda role policies independently..."

  # Do not trust the aggregate role_policies_applied flag here. An AWS policy
  # call may have succeeded immediately before deploy.sh crashed and before
  # state was checkpointed. Ownership tags were already verified above, so
  # independently remove each expected policy and tolerate only "already
  # absent" responses.
  iam_cleanup_allow_missing \
    "Detached managed Lambda logging policy" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    iam detach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn "$LOGGING_POLICY_ARN" \
    --no-cli-pager

  iam_cleanup_allow_missing \
    "Deleted inline Lambda S3 policy" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    iam delete-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "$LAMBDA_S3_POLICY_NAME" \
    --no-cli-pager

  iam_cleanup_allow_missing \
    "Deleted inline Lambda SQS policy" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    iam delete-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "$LAMBDA_SQS_POLICY_NAME" \
    --no-cli-pager

  update_destroy_state '.steps.role_policies_applied = false'

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    iam delete-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --no-cli-pager

  update_destroy_state '.resources.role.created = false'
fi

if [[ "$(jq -r '.resources.queue.created' "$STATE_FILE")" == true ]]; then
  log "Deleting SQS queue: $SQS_QUEUE_NAME"
  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    sqs delete-queue \
    --queue-url "$QUEUE_URL" \
    --no-cli-pager

  update_destroy_state \
    '.resources.queue.created = false |
     .resources.queue.url = "" |
     .steps.queue_policy_applied = false'
fi

if [[ "$(jq -r '.resources.bucket.created' "$STATE_FILE")" == true ]]; then
  log "Aborting incomplete multipart uploads..."

  multipart_json="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api list-multipart-uploads \
      --bucket "$BUCKET_NAME" \
      --output json --no-cli-pager
  )"

  while IFS= read -r encoded_upload; do
    [[ -n "$encoded_upload" ]] || continue
    upload_json="$(base64 --decode <<<"$encoded_upload")"
    upload_key="$(jq -r '.Key' <<<"$upload_json")"
    upload_id="$(jq -r '.UploadId' <<<"$upload_json")"

    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api abort-multipart-upload \
      --bucket "$BUCKET_NAME" \
      --key "$upload_key" \
      --upload-id "$upload_id" \
      --no-cli-pager
  done < <(jq -r '.Uploads[]? | @base64' <<<"$multipart_json")

  bucket_versioning="$(
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3api get-bucket-versioning \
      --bucket "$BUCKET_NAME" \
      --query Status --output text --no-cli-pager
  )"

  if [[ "$bucket_versioning" == "Enabled" || "$bucket_versioning" == "Suspended" ]]; then
    log "Deleting object versions and delete markers..."
    versions_json="$(
      aws \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api list-object-versions \
        --bucket "$BUCKET_NAME" \
        --output json --no-cli-pager
    )"

    while IFS= read -r delete_batch; do
      [[ -n "$delete_batch" ]] || continue
      aws \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        s3api delete-objects \
        --bucket "$BUCKET_NAME" \
        --delete "$delete_batch" \
        --no-cli-pager
    done < <(
      jq -c '
        [.Versions[]?, .DeleteMarkers[]?]
        | map({Key:.Key,VersionId:.VersionId})
        | . as $objects
        | range(0; length; 1000) as $start
        | {Objects:$objects[$start:$start + 1000],Quiet:true}
      ' <<<"$versions_json"
    )
  else
    log "Emptying unversioned S3 objects..."
    aws \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      s3 rm "s3://$BUCKET_NAME" \
      --recursive \
      --no-cli-pager
  fi

  aws \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    s3api delete-bucket \
    --bucket "$BUCKET_NAME" \
    --no-cli-pager

  update_destroy_state \
    '.resources.bucket.created = false |
     .steps.bucket_configured = false'
fi

trap - ERR
rm -f -- "$STATE_FILE"
log "Destruction complete. Deployment state removed."
