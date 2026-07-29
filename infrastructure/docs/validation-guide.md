# Validation guide

Run after a complete deployment:

```bash
./infrastructure/validate.sh
./infrastructure/validate.sh --config path/to/config
./infrastructure/validate.sh --keep-artifacts
```

Validation authenticates and verifies state before writing S3. It checks bucket
ownership, encryption, public-access block/public status and notification;
queue identity, tags, visibility timeout and semantic policy; exact IAM trust,
managed and inline policies with no extras; Lambda identity, role, runtime,
handler, memory, timeout, environment and health; and exact enabled mapping
configuration.

Three files—UTF-8, binary, and a name containing spaces—are uploaded under:

```text
<INCOMING_PREFIX>phase4-validation/<run-id>/
```

Expected outputs are under the equivalent compressed prefix with `.gz`.
Bounded polling accommodates S3, SQS, Lambda, and CloudWatch eventual
consistency. Every output passes `gzip -t`, is decompressed, and is compared
byte-for-byte with `cmp`. The source must be absent.

After processing, all three SQS approximate counts must be zero twice
consecutively. Current-window CloudWatch events must show completion and no
processing/runtime failure. Missing CloudWatch read permission is a failure,
not a skipped check.

By default only this run’s compressed objects are deleted. `--keep-artifacts`
prints exact retained S3 paths. The script never deletes infrastructure.

A successful summary reports three cases, source deletion, gzip comparison,
queue health, logs, and security as `PASS`. Timeouts usually mean a broken
notification, queue policy, mapping, function, or permissions. Invalid gzip or
content mismatch means processing corruption. A remaining source indicates
conditional deletion did not complete.

Useful read-only inspection:

```bash
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api get-bucket-notification-configuration --bucket "$BUCKET_NAME"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lambda get-event-source-mapping --uuid "$MAPPING_UUID"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" logs filter-log-events --log-group-name "/aws/lambda/$LAMBDA_FUNCTION_NAME"
```

Use values from validated state/config, never guessed resource names.
