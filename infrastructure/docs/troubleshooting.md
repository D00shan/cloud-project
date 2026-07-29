# Troubleshooting

Use the configured profile and region in every diagnostic. Correct the cause
and rerun; never delete arbitrary Console resources.

| Problem | Likely cause | Diagnostic | Safe action |
|---|---|---|---|
| Profile missing | AWS CLI profile not configured | `aws configure list-profiles` | Configure the named profile outside the repo |
| Expired credentials | SSO/session expired | `aws --profile "$AWS_PROFILE" sts get-caller-identity` | Refresh/login, then rerun |
| Wrong account | Profile points elsewhere | Same identity command | Select the intended disposable profile |
| Wrong region | `.env`/state mismatch | `aws configure get region --profile "$AWS_PROFILE"` | Restore original config; do not alter state |
| Bucket collision | Global name already used | `aws ... s3api head-bucket --bucket "$BUCKET_NAME"` | Choose a new temporary prefix before first deploy |
| IAM propagation | Role not yet usable | `aws ... iam get-role --role-name "$LAMBDA_ROLE_NAME"` | Let deploy retries finish; rerun safely |
| Destination validation failure | Restricted list/get permission or wrong output metadata | `aws ... s3api head-object --bucket "$BUCKET_NAME" --key '<compressed-key>'` | Inspect rendered/deployed S3 policy |
| Package/handler/runtime error | Bad ZIP root or config | `aws ... lambda get-function-configuration --function-name "$LAMBDA_FUNCTION_NAME"` | Repackage; destroy/redeploy if fingerprint changed |
| Missing permission | IAM/S3/SQS/Logs denies | Inspect CloudTrail/error and role policies | Fix portable template only if design requires it; redeploy temporary stack |
| Visibility timeout | Too short versus Lambda | `aws ... sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names VisibilityTimeout` | Use at least 6× Lambda timeout before deployment |
| Mapping not enabled | Mapping failed/disabled | `aws ... lambda get-event-source-mapping --uuid "$MAPPING_UUID"` | Correct reported config/permission; rerun deploy |
| Output timeout | Notification, queue policy, mapping, or Lambda failure | Inspect notification, queue counts, mapping and logs | Correct the owning step; rerun validation |
| Invalid gzip | Function/upload corruption | `gzip -t downloaded.gz` | Inspect current-run logs; do not accept artifact |
| Source not deleted | Conditional delete denied or source replaced | `aws ... s3api head-object --bucket "$BUCKET_NAME" --key '<source-key>'` | Check ETag race and S3 inline policy |
| Messages remain | Lambda failures/retries | `aws ... sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All` | Inspect current Lambda logs and mapping |
| Logs delayed/inaccessible | Eventual consistency or missing read permission | `aws ... logs filter-log-events --log-group-name "/aws/lambda/$LAMBDA_FUNCTION_NAME"` | Wait within timeout or grant operator read access |
| Destroy failure | Ambiguous lookup, ownership, or dependency | Rerun command and read exact AWS response | Preserve state; resolve only that dependency |
| State missing/stale | Manual deletion or wrong workspace | `jq . infrastructure/state/deployment.json` | Recover the correct local state; never infer targets |
| Fingerprint mismatch | Config/code changed after deploy | Compare `.env` and Git changes | Restore original inputs, destroy, then redeploy |
