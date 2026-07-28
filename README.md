# Project context

## Assignment
University project demonstrating an event-driven architecture using:
- Amazon S3
- Amazon SQS
- AWS Lambda

## Current architecture
1. User uploads a file into `incoming/` in S3.
2. S3 sends an ObjectCreated event directly to SQS.
3. SQS triggers the FileCompressionHandler Lambda.
4. Lambda downloads and gzip-compresses the object.
5. Lambda uploads it into `compressed/`.
6. Lambda deletes the original file.

## AWS details
Region: us-east-1
Bucket: cloud-project-file-sharing-bucket
Queue: file-compression-queue
Compression Lambda: FileCompressionHandler
Runtime: Node.js
AWS SDK: JavaScript v3

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

# Project TODO

* [x] Rename `index.js` to `index.mjs`
* [x] Add `package.json` and install the Lambda dependencies
* [ ] Test the corrected Lambda package locally and in AWS
* [ ] Copy the current Lambda configuration into the project documentation
* [ ] Copy all current IAM policies into JSON files
* [ ] Document the S3 notification and SQS event source mapping
* [ ] Install AWS CLI v2
* [ ] Configure the AWS CLI safely
* [ ] Reproduce the current resources through documented CLI commands
* [ ] Only then begin the web application
