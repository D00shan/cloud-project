#!/usr/bin/env bash
set -u -o pipefail

AWS_REGION="us-east-1"
EXPECTED_ACCOUNT_ID="555751475057"
BUCKET_NAME="cloud-project-file-sharing-bucket"
QUEUE_NAME="file-compression-queue"

ROOT_DIR="$(pwd)"
OUT_DIR="$ROOT_DIR/docs/current-aws-state"
S3_DIR="$OUT_DIR/s3"
SQS_DIR="$OUT_DIR/sqs"

mkdir -p "$S3_DIR" "$SQS_DIR"
export AWS_PAGER=""

capture_json() {
  local output_file="$1"
  shift

  echo "Exporting $(basename "$output_file")..."
  local error_file="${output_file%.json}.error.txt"

  if "$@" --output json --no-cli-pager > "$output_file" 2> "$error_file"; then
    rm -f "$error_file"
  else
    local exit_code=$?
    rm -f "$output_file"

    if grep -Eq '\((NoSuch[^)]*|[^)]*NotFound[^)]*)\)' "$error_file"; then
      local error_code
      error_code="$(sed -n 's/.*(\([^)]*\)).*/\1/p' "$error_file" | head -n 1)"
      printf '{\n  "Configured": false,\n  "Reason": "%s"\n}\n' "$error_code" > "$output_file"
      rm -f "$error_file"
    else
      {
        echo "Command failed with exit code $exit_code."
        echo "Review this error; it may indicate missing read permission or another unexpected problem."
        echo
        cat "$error_file"
      } > "${error_file}.tmp"
      mv "${error_file}.tmp" "$error_file"
    fi
  fi
}

echo "Checking AWS identity..."
ACCOUNT_ID="$(aws sts get-caller-identity \
  --query Account \
  --output text \
  --no-cli-pager)" || exit 1

if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  echo "Refusing to continue: expected AWS account $EXPECTED_ACCOUNT_ID, but the CLI is using $ACCOUNT_ID." >&2
  exit 1
fi

echo "Checking that the S3 bucket exists and is accessible..."
aws s3api head-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --no-cli-pager || exit 1

echo "Resolving the SQS queue URL..."
QUEUE_URL="$(aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query QueueUrl \
  --output text \
  --no-cli-pager)" || exit 1

capture_json "$OUT_DIR/caller-identity.json" \
  aws sts get-caller-identity

capture_json "$S3_DIR/bucket-location.json" \
  aws s3api get-bucket-location \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/versioning.json" \
  aws s3api get-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/encryption.json" \
  aws s3api get-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/bucket-public-access-block.json" \
  aws s3api get-public-access-block \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/account-public-access-block.json" \
  aws s3control get-public-access-block \
  --account-id "$ACCOUNT_ID" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/ownership-controls.json" \
  aws s3api get-bucket-ownership-controls \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/cors.json" \
  aws s3api get-bucket-cors \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/lifecycle.json" \
  aws s3api get-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/bucket-policy-response.json" \
  aws s3api get-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/notification-configuration.json" \
  aws s3api get-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/logging.json" \
  aws s3api get-bucket-logging \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/tags.json" \
  aws s3api get-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/acl.json" \
  aws s3api get-bucket-acl \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$S3_DIR/website.json" \
  aws s3api get-bucket-website \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

capture_json "$SQS_DIR/queue-url.json" \
  aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION"

capture_json "$SQS_DIR/queue-attributes.json" \
  aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names All \
  --region "$AWS_REGION"

capture_json "$SQS_DIR/queue-tags.json" \
  aws sqs list-queue-tags \
  --queue-url "$QUEUE_URL" \
  --region "$AWS_REGION"

python3 - "$S3_DIR" "$SQS_DIR" <<'PY'
import json
import pathlib
import sys

s3_dir = pathlib.Path(sys.argv[1])
sqs_dir = pathlib.Path(sys.argv[2])

bucket_response = s3_dir / "bucket-policy-response.json"
if bucket_response.exists():
    data = json.loads(bucket_response.read_text())
    policy = data.get("Policy")
    if policy:
        (s3_dir / "bucket-policy.json").write_text(
            json.dumps(json.loads(policy), indent=2) + "\n"
        )

queue_attributes = sqs_dir / "queue-attributes.json"
if queue_attributes.exists():
    data = json.loads(queue_attributes.read_text())
    policy = data.get("Attributes", {}).get("Policy")
    if policy:
        (sqs_dir / "queue-policy.json").write_text(
            json.dumps(json.loads(policy), indent=2) + "\n"
        )
PY

echo
echo "Inventory complete. Files are under:"
echo "  $OUT_DIR"
echo
echo "Any *.error.txt files need review; they indicate a read-permission problem or another unexpected error."
