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
- `render-templates.sh` — derives identifiers, then renders and validates portable JSON configuration
- `package-lambda.sh` — installs production dependencies in an isolated staging directory and creates the Lambda ZIP

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

The renderer reads `infrastructure/.env` by default:

```bash
./infrastructure/render-templates.sh
```

An explicit config path can be passed as the first argument. Using its configured
AWS profile and region, the renderer calls only `aws sts get-caller-identity`.
It derives the account ID and partition from that response, builds the bucket
name from `BUCKET_NAME_PREFIX`, account ID, and region, and constructs the
bucket and queue ARNs locally. This identity lookup is read-only and does not
create or modify AWS resources.

The renderer only supports the placeholders `BUCKET_ARN`, `QUEUE_ARN`,
`ACCOUNT_ID`, `INCOMING_PREFIX`, and `COMPRESSED_PREFIX`. It uses JSON-aware
substitution, rejects unsupported or unresolved placeholders, validates ARN
consistency and every generated document, and preserves the previous valid
output if a new render fails.

Deployment-ready JSON is written to `build/generated-config/`. Source templates
are never modified, and everything under `build/` is ignored by Git and must not
be committed. Rendering and JSON validation are preparation steps; the renderer
performs a read-only identity lookup but does not deploy or modify AWS resources.

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

## Package the Lambda

```bash
./infrastructure/package-lambda.sh
```

Packaging removes the previous package build, copies the Lambda source into an
ignored staging directory, runs `npm ci --omit=dev`, creates
`build/lambda-package/compression-handler.zip`, and verifies that `index.mjs`,
`package.json`, and `node_modules/` are at the ZIP root. It does not install
dependencies in the source directory.

## Deploy

> **Safety warning:** Keep the original manually created infrastructure
> untouched. The first real CLI deployment must use a separate temporary
> environment and distinct resource names.

After copying and reviewing `.env`, deploy with:

```bash
./infrastructure/deploy.sh
```

Deployment runs preflight, renders JSON, packages the Lambda, and then creates
the private S3 bucket, SQS queue, Lambda execution role, Lambda function, event
source mapping, and S3 notification in dependency order. It attaches the
AWS-managed `AWSLambdaBasicExecutionRole` policy and adds the two rendered
least-privilege application policies as inline role policies.

Generated JSON is stored under `build/generated-config/`, the Lambda ZIP under
`build/lambda-package/`, and deployment ownership state under
`state/deployment.json`. All are ignored by Git.

### Idempotency and collisions

The first implementation is deliberately conservative:

- An empty deterministic namespace can be deployed.
- Before the first resource mutation, all deterministic S3, SQS, IAM, and
  Lambda names are checked for collisions.
- An unrelated or ambiguous existing resource causes a clear refusal. The
  deployment never adopts, overwrites, or deletes it.
- State is written atomically before resource creation and after each tagged
  resource is recorded.
- A rerun may continue only when state matches the authenticated account,
  partition, region, profile, project, environment, and every deterministic
  resource name.
- Existing resources are reused only when state records their creation and
  their `DeploymentId`, `Project`, and `Environment` ownership tags match.
- Recorded configuration steps may be reapplied to those proven-owned
  resources. This is interruption recovery, not general reconciliation.

If deployment stops, keep `state/deployment.json`. Inspect the reported
resource, correct the underlying issue, and rerun the same command with the same
configuration. If a resource was created but could not be tagged and recorded,
the script refuses to adopt it; inspect and resolve that collision manually
instead of deleting anything automatically.

## Destroy

Interactive teardown:

```bash
./infrastructure/destroy.sh
```

For automation, the exact configured project/environment identifier is still
required:

```bash
./infrastructure/destroy.sh --yes 'cloud-file-compression/cli-test'
```

Teardown requires valid state, authenticates with the state profile and region,
re-derives every deterministic name, verifies account/configuration equality,
and checks ownership tags before showing the plan. It then requires the exact
project/environment confirmation.

Resources are removed in reverse dependency order: event-source mapping, S3
notification, Lambda function, role policies and role, SQS queue, multipart
uploads and bucket objects/versions when applicable, and finally the S3 bucket.
Local state is removed only after every cleanup step succeeds. On partial
failure, state is preserved and the script prints recovery guidance.

Neither deployment nor destruction accepts resource names as command-line
targets. This prevents arbitrary resources—including the historical stack—from
being selected without matching state created by this deployment system.
