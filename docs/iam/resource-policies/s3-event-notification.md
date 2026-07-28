# S3 Event Notification

| Property | Value |
|---|---|
| Name | QueueIncomingUploads |
| Bucket | cloud-project-file-sharing-bucket |
| Event | All object create events |
| Prefix | incoming/ |
| Suffix | None |
| Destination | SQS |
| Queue ARN | Copy from AWS |

The SQS queue access policy allows this bucket to call `sqs:SendMessage`.