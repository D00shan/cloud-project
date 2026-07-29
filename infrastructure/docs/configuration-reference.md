# Configuration reference

Copy `config/project.env.example` to `infrastructure/.env`. Values are trusted
Bash assignments; do not put commands or credentials in the file.

| Variable | Purpose / example | Format | Naming impact | Change after deploy |
|---|---|---|---|---|
| `AWS_PROFILE` | CLI profile, `default` | Existing profile name | State identity | Refused |
| `AWS_REGION` | AWS region, `us-east-1` | AWS region identifier | Bucket/queue/Lambda ARNs | Refused |
| `PROJECT_NAME` | Project tag, `cloud-file-compression` | Lowercase letters/digits/hyphens | Ownership/deployment ID | Refused |
| `ENVIRONMENT` | Temporary environment, `cli-test` | Lowercase letters/digits/hyphens | Ownership/deployment ID | Refused |
| `BUCKET_NAME_PREFIX` | Bucket namespace | Valid lowercase S3 prefix | Yes | Refused |
| `INCOMING_PREFIX` | Input keys, `incoming/` | No leading `/`; trailing `/` | Policies/notification/Lambda | Refused |
| `COMPRESSED_PREFIX` | Output keys, `compressed/` | Distinct; trailing `/` | Policies/Lambda | Refused |
| `SQS_QUEUE_NAME` | Queue name | 1–80 allowed SQS characters | Yes | Refused |
| `SQS_VISIBILITY_TIMEOUT` | Retry visibility, `180` | Integer 0–43200; at least 6× Lambda timeout | Queue configuration | Refused |
| `LAMBDA_FUNCTION_NAME` | Function name | 1–64 Lambda name characters | Yes | Refused |
| `LAMBDA_ROLE_NAME` | Execution role name | Valid IAM role name, ≤64 | Yes | Refused |
| `LAMBDA_RUNTIME` | Runtime, `nodejs22.x` | `nodejs<number>.x` | Function config | Refused |
| `LAMBDA_MEMORY_SIZE` | Memory MB, `256` | 128–10240 | Function config | Refused |
| `LAMBDA_TIMEOUT` | Timeout seconds, `30` | 1–900 | Function/queue safety | Refused |

The final bucket name is:

```text
<BUCKET_NAME_PREFIX>-<ACCOUNT_ID>-<AWS_REGION>
```

Account and partition come from `sts get-caller-identity`; ARNs are derived
locally. The conservative deployment fingerprint intentionally rejects changed
configuration or Lambda packages. Normally destroy the temporary stack using
its original `.env`, then edit configuration and deploy from empty state.
