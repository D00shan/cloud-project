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