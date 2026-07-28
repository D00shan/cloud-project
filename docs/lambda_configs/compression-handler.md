# FileCompressionHandler

| Setting | Value |
|---|---|
| Function name | FileCompressionHandler |
| Region | us-east-1 |
| Runtime | Node.js 24.x |
| Architecture | x86_64 |
| Handler | index.handler |
| Memory | 128 MB |
| Timeout | 3 seconds |
| Execution role | FileCompressionHandler-role-fntiwpdd |
| Ephemeral storage | 512 MB |

## Environment variables

No environment variables are currently configured.

<!-- Replace the sentence above with a table if variables are used. -->

## SQS trigger

| Setting | Value |
|---|---|
| Queue name | file-compression-queue |
| Queue ARN | arn:aws:sqs:us-east-1:555751475057:file-compression-queue |
| Trigger status | Enabled |
| Batch size | 1 |
| Batch window | None |
| Partial batch responses | Enabled |
| Maximum concurrency | None |

## Processing behavior

1. S3 sends an object-created event to SQS when a file is uploaded under `incoming/`.
2. SQS invokes `FileCompressionHandler`.
3. The Lambda downloads the source object from S3.
4. The Lambda compresses the file.
5. The compressed output is uploaded under `compressed/`.
6. The original object is deleted after successful processing.

## Deployment package

The deployment archive is generated from:

`lambdas/compression-handler/`

Run:

```bash
npm install
npm run package