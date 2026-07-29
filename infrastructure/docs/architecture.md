# Architecture

```text
Client or AWS CLI
        |
        v
S3 incoming object
        |
        v
S3 ObjectCreated notification
        |
        v
SQS queue
        |
        v
Lambda event-source mapping
        |
        v
Compression Lambda
        |
        +--> compressed/<source path>.gz
        |
        +--> conditionally deletes incoming source
```

## Resources and dependencies

| Resource | Purpose and creator | Permission/dependency | Teardown |
|---|---|---|---|
| S3 bucket | `deploy.sh` creates private input/output storage | S3 policy limits Lambda to configured prefixes | Last |
| SQS queue | Buffers S3 events and retries delivery | Queue policy permits only configured S3 bucket/account | Before bucket |
| SQS resource policy | Allows `s3.amazonaws.com` `SendMessage` | Source ARN/account conditions | Removed with queue |
| IAM role | Lambda execution identity | Trust policy permits Lambda only | After function |
| Managed logging policy | `AWSLambdaBasicExecutionRole` writes logs | Attached to role | Detached before role |
| Inline S3 policy | Read/delete incoming; read/write/abort compressed; restricted compressed listing | Attached to role | Deleted before role |
| Inline SQS policy | Receive/delete/get attributes on one queue | Attached to role | Deleted before role |
| Lambda function | Gzip compression and source cleanup | Uses role; configured prefixes | After notification/mapping |
| Event-source mapping | Polls SQS and invokes Lambda | Queue and function must exist | First |
| S3 notification | Publishes incoming `ObjectCreated` events | Queue policy must already allow S3 | Before queue/function |
| CloudWatch log group | Created by Lambda logging on first invocation | Managed logging policy | Not explicitly managed by Phase 3 teardown |
| Local deployment state | Atomic ownership and recovery record | Required by validation/destruction | Removed after successful teardown |

The mapping uses batch size one and `ReportBatchItemFailures`. Lambda still
returns only genuinely failed SQS message IDs, preventing successful messages
from being retried.

SQS delivery is at least once. The function stores source bucket, encoded key,
opaque ETag, and optional version ID in destination metadata. Matching metadata
proves a duplicate is complete. Conditional `GetObject` and `DeleteObject`
protect a newer object that reused the key; a `412` stale event succeeds without
deleting the replacement. A mismatching destination is never overwritten.
