# Deployment guide

> Keep the original working stack untouched. Use distinct temporary names and
> complete two deploy/validate/destroy cycles before considering any migration.

## Prerequisites

Use Linux Bash, Node.js/npm, AWS CLI v2, `jq`, `zip`, `unzip`, `gzip`,
`gunzip`, and `cmp`. Configure an AWS CLI profile with credentials for a
disposable account or isolated environment. The scripts use the profile and
region explicitly and require permission to create the documented resources.
Do not paste credentials into this repository.

Clone the repository and enter it, then create local configuration:

```bash
cp infrastructure/config/project.env.example infrastructure/.env
# edit infrastructure/.env and review every value
```

Choose temporary `PROJECT_NAME`, `ENVIRONMENT`, bucket prefix, queue, Lambda,
and role names that cannot collide with the original stack. See
[configuration-reference.md](configuration-reference.md).

## Local proof and preflight

```bash
./test.sh
./infrastructure/preflight.sh
./infrastructure/package-lambda.sh
```

Local tests use mocks. Preflight checks tools, configuration, AWS identity,
bucket-name availability, and AWS CLI support for atomically tagged bucket
creation. Packaging uses `npm ci --omit=dev` and writes only ignored build
artifacts.

S3 “folders” are key prefixes. Do not create `incoming/` or `compressed/`
manually. Uploading an `incoming/...` key creates that logical path, and Lambda
writes the matching `compressed/...gz` key.

## Deploy and validate

```bash
./infrastructure/deploy.sh
./infrastructure/validate.sh
```

Deployment creates the private bucket, queue and resource policy, role and
policies, function, event-source mapping, and notification. It records ownership
in `infrastructure/state/deployment.json`. Validation checks configuration and
security before uploading three unique smoke-test objects, then proves gzip
output byte-for-byte.

If a command fails, keep the state file. Read
[troubleshooting.md](troubleshooting.md); reruns adopt only exactly matching,
owned resources. Never solve a collision by deleting an arbitrary resource.

## Destroy and repeat from empty state

```bash
./infrastructure/destroy.sh
# or:
./infrastructure/destroy.sh --yes '<PROJECT_NAME>/<ENVIRONMENT>'
```

Confirm state is gone and the recorded bucket, queue, function, role, and
mapping are absent. Confirm the original stack is unchanged. Then repeat:

```bash
./infrastructure/preflight.sh
./infrastructure/deploy.sh
./infrastructure/validate.sh
./infrastructure/destroy.sh --yes '<PROJECT_NAME>/<ENVIRONMENT>'
```

Record both cycles in [portability-rehearsal.md](portability-rehearsal.md).
Only two successful real cycles prove the rehearsal.
