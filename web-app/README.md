# Cloud File Compressor web application

This standalone Express application provides a browser interface for the
existing private S3 → SQS → Lambda compression pipeline. It communicates only
with S3:

1. the backend uploads a file below the configured `incoming/` prefix;
2. the existing AWS pipeline compresses it asynchronously;
3. the backend compares `incoming/` and `compressed/` objects to show status;
4. ready files are downloaded through short-lived presigned S3 URLs.

The browser never receives AWS credentials, and the S3 bucket remains private.

## Prerequisites

- Node.js 20 or newer
- npm
- an already deployed compression pipeline
- AWS credentials available to the SDK's default credential-provider chain
- a backend AWS identity with the minimum S3 permissions described below

## Install and configure

From `web-app/`:

```bash
npm ci
cp .env.example .env
```

Review every value in `.env`:

| Variable | Purpose |
| --- | --- |
| `PORT` | Local HTTP port. |
| `AWS_PROFILE` | Optional local AWS CLI profile used by the default SDK chain. |
| `AWS_REGION` | Region containing the deployed S3 bucket. |
| `S3_BUCKET_NAME` | Private bucket used by the compression pipeline. |
| `INCOMING_PREFIX` | Source-object prefix; normalized to one trailing slash. |
| `COMPRESSED_PREFIX` | Output-object prefix; normalized to one trailing slash. |
| `MAX_UPLOAD_BYTES` | Multipart upload limit in bytes. |
| `DELAYED_AFTER_SECONDS` | Age at which an incoming-only upload is delayed. |
| `DOWNLOAD_URL_TTL_SECONDS` | Presigned download lifetime, up to one hour. |
| `FILE_LIST_LIMIT` | Maximum number of recent uploads returned by the API. |
| `POLL_INTERVAL_MS` | Browser refresh interval, at least one second. |

The example contains no account-specific resources or credentials. Do not
commit `.env`.

## AWS credentials

The application constructs `S3Client` with only the configured region. AWS SDK
for JavaScript v3 discovers credentials through its default provider chain.
For local development, `AWS_PROFILE` can select an AWS CLI profile. In a future
AWS runtime, an attached IAM role works without code changes.

Never put access keys in source files or browser JavaScript.

## Run

```bash
npm start
```

For automatic server restarts during development:

```bash
npm run dev
```

Open `http://localhost:3000/`. The upload page accepts one file, and the recent
files page polls while it is open.

## S3 key behavior

Every upload gets a server-generated timestamp and UUID, so the same visible
filename can be uploaded repeatedly without overwriting an earlier result:

```text
incoming/<UTC-timestamp>_<UUID>/report.pdf
compressed/<UTC-timestamp>_<UUID>/report.pdf.gz
```

Filenames are reduced to a safe basename, control and path-separator characters
are removed or replaced, and traversal segments cannot escape the generated
upload path.

Recent-file status is derived without a database:

- an incoming object without output is `processing`;
- an incoming object beyond the configured threshold is `delayed`;
- a matching compressed object is `ready`, including after Lambda deletes the
  incoming source.

S3 listings are explicitly sorted newest-first by object modification time.

## API

- `GET /health` returns inexpensive process health.
- `POST /api/uploads` accepts a multipart field named `file` and returns
  `202 Accepted` once S3 stores the source.
- `GET /api/files` returns recent normalized upload states.
- `POST /api/files/download-url` accepts a ready `compressedKey`.

Download requests are restricted to the configured compressed prefix and the
application's timestamp/UUID key format. The backend verifies the object exists
before creating a short-lived presigned GET URL. It never signs arbitrary keys.

## Minimum backend IAM permissions

The backend identity needs only:

```text
s3:PutObject
    <bucket>/incoming/*

s3:GetObject
    <bucket>/compressed/*

s3:ListBucket
    <bucket>, restricted with s3:prefix to incoming/* and compressed/*
```

`HeadObject` authorization uses `s3:GetObject`. The application does not need:

```text
s3:DeleteObject
sqs:*
lambda:*
iam:*
```

Presigned downloads authorize the caller using the backend identity's
`s3:GetObject` permission; they do not make the bucket public.

## Tests

```bash
npm test
```

Tests use Node's built-in runner, injected S3 clients, and Supertest for
lightweight Express route requests. They do not use AWS credentials or contact
AWS.

## Manual end-to-end test

1. Confirm the existing disposable AWS stack is deployed and healthy.
2. Configure `.env` with its region, bucket, and matching prefixes.
3. Start the web application.
4. Upload a small text or binary file.
5. Confirm the upload page reports asynchronous processing.
6. Open Recent files and observe `processing` transition to `ready`.
7. Download the `.gz` file and verify it decompresses to the original bytes.
8. Upload a different file with the same visible filename and confirm both
   uploads have independent entries and downloads.

No SQS or Lambda call is made by this application.

## Troubleshooting

- **Startup reports a missing variable:** copy `.env.example` to `.env` and
  provide every required AWS and bucket value.
- **Credentials cannot be loaded:** run `aws sts get-caller-identity` with the
  configured profile, renew the local session if needed, and restart the app.
- **Upload is rejected:** check `MAX_UPLOAD_BYTES`, ensure the file is nonempty,
  and verify `s3:PutObject` on the incoming prefix.
- **Files cannot be listed:** verify `s3:ListBucket` is allowed for both
  configured prefixes and that the configured bucket and region match.
- **An upload remains processing or delayed:** inspect the existing S3 → SQS →
  Lambda pipeline and its CloudWatch logs; the web app does not invoke it
  directly.
- **Download preparation fails:** confirm the output exists and the backend has
  `s3:GetObject` on the compressed prefix.
- **A 500 response appears:** inspect server logs. Responses intentionally omit
  internal stack traces, credentials, and signed URLs.
