# Project context

## Assignment
University project demonstrating an event-driven architecture using:
- Amazon S3
- Amazon SQS
- AWS Lambda

## Current architecture
1. User uploads a file into `incoming/` in S3.
2. S3 sends an ObjectCreated event directly to SQS.
3. SQS triggers the configured compression Lambda.
4. Lambda downloads and gzip-compresses the object.
5. Lambda uploads it into `compressed/`.
6. Lambda deletes the original file.

## AWS details

The region and deterministic resource names come from
`infrastructure/.env`; account and partition values are derived from the
authenticated AWS CLI identity. The compression function uses Node.js and AWS
SDK for JavaScript v3.

## Requirements
- Infrastructure must also be reproducible through AWS CLI.
- A web application should demonstrate uploads and processing.
- User should be able to download files through the web app
- The final project needs documentation and a presentation.
- Explain all AWS concepts in beginner-friendly terms.

## Current problems
- [Add current errors here]

## Important rules
- Do not change the architecture without explaining why.
- Provide complete working files, not isolated fragments.
- Include required IAM permissions with every AWS component.
- Clearly distinguish console instructions from CLI instructions.

## Portable AWS CLI workflow

Use distinct names and an isolated environment for a disposable rehearsal:

```bash
cp infrastructure/config/project.env.example infrastructure/.env
# edit infrastructure/.env

./test.sh
./infrastructure/preflight.sh
./infrastructure/deploy.sh
./infrastructure/validate.sh
./infrastructure/destroy.sh
```

After confirming the temporary resources and state are gone, deploy, validate,
and destroy the same configuration a second time from empty state. Detailed
beginner guides and the uncompleted rehearsal evidence checklist are indexed in
[infrastructure/docs/README.md](infrastructure/docs/README.md). Local tests do
not prove real AWS portability; only two successful disposable AWS cycles do.

# Project TODO
