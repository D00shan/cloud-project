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

Detailed operator documentation is indexed in
[`docs/README.md`](docs/README.md).

## Policy and integration templates

Files in `config/templates/` are portable source documents:

- `lambda-trust-policy.json` allows the Lambda service to assume the execution role.
- `lambda-s3-policy.json.template` limits the function to reading and deleting
  incoming objects, reading/writing compressed objects, and listing only the
  compressed prefix.
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

Preflight also verifies that the installed AWS CLI v2 model supports S3 bucket
tags inside `CreateBucketConfiguration`. Deployment deliberately has no
create-then-tag fallback: ownership tags must be part of `CreateBucket` so an
interruption cannot leave an untagged bucket that looks adoptable. Upgrade AWS
CLI v2 if this capability check fails.

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

The complete portable rehearsal workflow is:

```bash
cp infrastructure/config/project.env.example infrastructure/.env
# edit infrastructure/.env
./test.sh
./infrastructure/preflight.sh
./infrastructure/deploy.sh
./infrastructure/validate.sh
./infrastructure/destroy.sh
```

Use separate temporary names, confirm teardown, and repeat deploy, validation,
and destruction from empty state. Do not modify the original stack.

Deployment runs preflight, renders JSON, packages the Lambda, and then creates
the private S3 bucket, SQS queue, Lambda execution role, Lambda function, event
source mapping, and S3 notification in dependency order. It attaches the
AWS-managed `AWSLambdaBasicExecutionRole` policy and adds the two rendered
least-privilege application policies as inline role policies.

Bucket creation sends `DeploymentId`, `Project`, and `Environment` tags in the
same `CreateBucket` request as `BucketOwnerEnforced` ownership and the regional
location constraint. Deployment waits for the bucket and verifies those tags
before atomically recording bucket creation in local state.

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
- If an AWS create/configuration call succeeded immediately before an
  interruption, a rerun can adopt the uncheckpointed result. Adoption requires
  the expected account, partition, region, name/ARN, and exact
  `DeploymentId`, `Project`, and `Environment` tags. The queue settings, role
  trust/policies, Lambda code hash and configuration, event-source mapping
  endpoints/batch settings, and S3 notification/filter must also exactly match
  where applicable. A name match alone is never sufficient.
- Each successful adoption is checkpointed atomically before deployment
  continues, so later deployment and teardown treat it exactly like a resource
  recorded during its original create call.
- Recorded configuration steps may be reapplied to those proven-owned
  resources. This is interruption recovery, not general reconciliation.
- The initial deployment records a normalized configuration fingerprint and
  the exact Lambda ZIP SHA-256 hash. The configuration fingerprint also covers
  every rendered policy/notification document and fixed Lambda handler,
  architecture, and S3 safety settings. A rerun proceeds only when both hashes
  still match. Changed Lambda code, runtime, handler-related settings, memory,
  timeout, prefixes, queue visibility timeout, templates, or other recorded
  configuration causes a refusal before any AWS mutation.
- When a fingerprint differs, destroy the parallel temporary stack using its
  original configuration and deploy it again. The script never silently leaves
  AWS running a mixture of old and new configuration.
- An existing event-source mapping is adopted only when its queue/function,
  batch size, zero batching window, partial-batch response setting, filters,
  scaling, destination, and source-specific configuration match. `Enabled`,
  `Creating`, `Enabling`, and `Updating` are the only acceptable states.
  Adoption records the UUID while leaving the enabled checkpoint false. The
  checkpoint becomes true only after a later AWS lookup reports `Enabled`;
  disabled, failed, deleting, unknown, or timed-out mappings fail closed.

If deployment stops, keep `state/deployment.json` and rerun with the same
configuration. Exactly matching tagged resources and configurations are
adopted; missing ownership tags, foreign identities, or configuration
differences are reported as collisions and are never mutated automatically.

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
After role ownership tags are verified, teardown independently detaches the
managed logging policy and deletes both expected inline policies. Already
missing policies are accepted; authorization and other unexpected AWS errors
remain fatal. This makes cleanup safe when deployment stopped between IAM
operations and its state checkpoint.
Local state is removed only after every cleanup step succeeds. On partial
failure, state is preserved and the script prints recovery guidance.
Before the destruction plan, every recorded resource is looked up
independently. An exact AWS not-found response is checkpointed atomically as
already deleted, while `AccessDenied`, expired authentication, networking,
throttling, malformed output, and other ambiguous failures stop teardown. This
allows a rerun to continue after deletion succeeded immediately before a crash
without weakening foreign-resource protection.

Neither deployment nor destruction accepts resource names as command-line
targets. This prevents arbitrary resources—including the historical stack—from
being selected without matching state created by this deployment system.

## Phase 3 local safety tests

Run the isolated AWS CLI simulator suite with:

```bash
./infrastructure/tests/phase3-safety-tests.sh
```

The suite uses temporary repository copies and a local AWS mock. It exercises a
fresh deployment, an unchanged rerun, configuration/code drift refusal, IAM
and resource-creation crash recovery, exact adoption and collision refusal,
restart-safe already-absent destruction, missing-policy cleanup, fatal lookup
and authorization errors, ownership refusal, shell syntax, and template JSON
without using real AWS credentials.

## Duplicate delivery behavior

The compression Lambda is idempotent for SQS duplicate delivery. Every
compressed object records the source bucket, URL-encoded source key, normalized
source ETag, and source version ID when supplied by the event as S3 user
metadata. Before uploading, the handler heads the deterministic compressed key.
A metadata match proves that the exact source was already processed, so source
deletion is retried idempotently and the SQS message succeeds. A missing source
also succeeds only when matching destination metadata proves prior completion.
Mismatched destination metadata and ambiguous destination lookup failures such
as `AccessDenied` remain genuine partial-batch failures; existing output is
never silently overwritten.

The generated Lambda S3 policy grants `s3:GetObject` on the compressed-output
prefix solely for this destination metadata check. It also grants
`s3:ListBucket` on the bucket ARN with an `s3:prefix` condition restricted to
the compressed prefix. S3 can otherwise return `403 AccessDenied` for a missing
`HeadObject`, making it impossible to distinguish a new destination from a real
authorization failure. No unrelated prefix can be listed.

Source ETags are opaque and case-sensitive. Both source download and deletion
use the event ETag as an `IfMatch` condition. If a newer object reuses the same
key before download, S3 returns `412 PreconditionFailed`; the stale event
succeeds without reading, compressing, or deleting the replacement. If the key
changes after download, the compressed result may finish, but conditional
deletion returns `412` and the replacement remains untouched. `AccessDenied`
and unexpected errors remain genuine SQS partial-batch failures.

## Local test suite

Run every Phase 3 simulator and Lambda regression test from the repository
root:

```bash
./test.sh
```

The command does not use AWS credentials or contact AWS. It creates isolated
temporary workspaces, uses the local AWS CLI fixture, packages the Lambda in an
ignored build directory, and fails on the first unsuccessful suite.

Manual testing is still required in a disposable AWS account/environment:
interrupt each create/configuration step after AWS accepts it and verify rerun
adoption, interrupt each deletion before its state checkpoint and verify
restart, and redeliver an S3/SQS event after source deletion to verify metadata
matching and conditional `GetObject`/`DeleteObject` behavior against real S3
and Lambda event shapes. Also verify the installed AWS CLI accepts atomic S3
creation tags and observe `Creating` to `Enabled` event-source mapping
transitions. Do not use the historical stack for these tests.
