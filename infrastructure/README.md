# Portable AWS CLI Infrastructure

This directory contains the reusable, account-independent AWS CLI
implementation for the cloud file-compression project.

Files under this directory must not depend on the original AWS account ID,
existing resource ARNs, queue URLs, generated UUIDs, or console-generated IAM
names.

## Directory layout

- `config/` — user configuration and source templates
- `config/templates/` — portable JSON templates
- `lib/` — shared Bash functions
- `build/` — generated deployment files and Lambda packages
- `state/` — locally recorded identifiers for deployed resources
- `docs/` — deployment and infrastructure documentation
- `deploy.sh` — creates or updates the infrastructure
- `validate.sh` — validates configuration and generated files
- `destroy.sh` — removes infrastructure in reverse dependency order
- `preflight.sh` — verifies local dependencies, configuration, AWS identity, selected region, and bucket-name availability without modifying AWS resources
- `render-templates.sh` — renders and validates portable JSON configuration without calling AWS

## Policy and integration templates

Files in `config/templates/` are portable source documents:

- `lambda-trust-policy.json` allows the Lambda service to assume the execution role.
- `lambda-s3-policy.json.template` limits the function to reading and deleting incoming objects and writing compressed objects.
- `lambda-sqs-policy.json.template` limits the function to consuming messages from the configured queue.
- `sqs-resource-policy.json.template` allows only the configured S3 bucket and account to send messages to the configured queue.
- `s3-notification.json.template` sends object-created events under the configured incoming prefix to that queue.

CloudWatch Logs permissions are intentionally not duplicated in a custom policy.
During deployment, the Lambda execution role will use the AWS-managed
service-role policy `AWSLambdaBasicExecutionRole`. The deployment attachment is
part of Phase 3 and is not performed by the renderer.

## Render and validate templates

The renderer reads `infrastructure/.env` by default for the configured prefixes.
The future deployment workflow must also supply its derived `ACCOUNT_ID`,
`BUCKET_ARN`, and `QUEUE_ARN` values explicitly:

```bash
ACCOUNT_ID=123456789012 \
BUCKET_ARN=arn:aws:s3:::example-portable-bucket \
QUEUE_ARN=arn:aws:sqs:us-east-1:123456789012:example-portable-queue \
./infrastructure/render-templates.sh
```

An explicit config path can be passed as the first argument. The renderer only
supports the placeholders `BUCKET_ARN`, `QUEUE_ARN`, `ACCOUNT_ID`,
`INCOMING_PREFIX`, and `COMPRESSED_PREFIX`. It uses JSON-aware substitution,
rejects unsupported or unresolved placeholders, and validates every generated
document before replacing the previous output.

Deployment-ready JSON is written to `build/generated-config/`. Source templates
are never modified, and everything under `build/` is ignored by Git and must not
be committed. Rendering and JSON validation are local preparation steps; they
do not deploy or modify AWS resources.

## Preflight check

Copy the example configuration:

```bash
cp infrastructure/config/project.env.example infrastructure/.env
```

edit the AWS_PROFILE and AWS_REGION if necessary and run:

```bash
./infrastructure/preflight.sh
```

The original manually created AWS environment is documented separately under
`docs/current-aws-state/`.
