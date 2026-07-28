# S3 to SQS Event Notification

This notification sends an SQS message whenever an object is created under
the `incoming/` prefix in the project bucket.

| Setting | Value |
|---|---|
| Notification name | QueueIncomingUploads |
| Source bucket | cloud-project-file-sharing-bucket |
| Event label | All object create events |
| AWS event value | s3:ObjectCreated:* |
| Prefix filter | incoming/ |
| Suffix filter | None |
| Destination type | SQS queue |
| Destination queue | file-compression-queue |
| Queue ARN | arn:aws:sqs:us-east-1:555751475057:file-compression-queue |

## Required queue permission

The queue resource policy allows the S3 service to perform:

`sqs:SendMessage`

The permission is restricted to:

- AWS account `555751475057`
- S3 bucket `cloud-project-file-sharing-bucket`

The complete queue policy is stored at:

`docs/iam/resource-policies/sqs-queue-policy.json`