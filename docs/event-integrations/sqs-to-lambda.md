# SQS to Lambda Event Source Mapping

This event source mapping polls `file-compression-queue` and invokes the
`FileCompressionHandler` Lambda function when messages are available.

| Setting | Value |
|---|---|
| Event source mapping UUID | 3fdaea3b-b51c-4c87-be55-7e792704c071 |
| Source queue | file-compression-queue |
| Queue ARN | arn:aws:sqs:us-east-1:555751475057:file-compression-queue |
| Target function | FileCompressionHandler |
| Function ARN | arn:aws:lambda:us-east-1:555751475057:function:FileCompressionHandler |
| State | Enabled |
| Batch size | 1 |
| Maximum batching window | 0 seconds |
| Partial batch responses | Enabled |
| Function response type | ReportBatchItemFailures |
| Maximum concurrency | Not configured |

## Processing behavior

Lambda polls the SQS queue through this event source mapping. SQS does not
directly call the Lambda function.

When processing succeeds, Lambda removes the successfully processed messages
from the queue.

When individual records fail, the function returns their SQS message IDs under
`batchItemFailures`. Because `ReportBatchItemFailures` is enabled, only those
failed records become visible in the queue again.