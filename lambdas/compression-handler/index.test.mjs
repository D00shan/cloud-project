import test from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";

import { createHandler } from "./index.mjs";

const bucket = "portable-test-bucket";
const sourceKey = "incoming/file name.txt";
const destinationKey = "compressed/file name.txt.gz";
const sourceETag = "abc123";

function notFound(name = "NotFound") {
  return Object.assign(new Error(name), {
    name,
    $metadata: { httpStatusCode: 404 },
  });
}

function s3Record({ key = sourceKey, eTag = sourceETag } = {}) {
  return {
    eventSource: "aws:s3",
    eventName: "ObjectCreated:Put",
    s3: {
      bucket: { name: bucket },
      object: {
        key: encodeURIComponent(key).replace(/%20/g, "+"),
        eTag,
        size: 12,
      },
    },
  };
}

function sqsRecord(messageId, record = s3Record()) {
  return {
    messageId,
    eventSource: "aws:sqs",
    body: JSON.stringify({ Records: [record] }),
  };
}

function expectedMetadata({ eTag = sourceETag } = {}) {
  return {
    "source-bucket": bucket,
    "source-key": encodeURIComponent(sourceKey),
    "source-etag": eTag,
  };
}

function createS3Harness({
  sourcePresent = true,
  destinationMetadata = null,
  denyDestinationHead = false,
} = {}) {
  const state = {
    sourcePresent,
    destinationMetadata,
    uploadCount: 0,
    deleteCount: 0,
  };

  const s3Client = {
    async send(command) {
      if (command instanceof HeadObjectCommand) {
        if (denyDestinationHead) {
          throw Object.assign(new Error("AccessDenied"), {
            name: "AccessDenied",
          });
        }

        if (!state.destinationMetadata) {
          throw notFound();
        }

        return {
          Metadata: state.destinationMetadata,
        };
      }

      if (command instanceof GetObjectCommand) {
        if (!state.sourcePresent) {
          throw notFound("NoSuchKey");
        }

        return {
          Body: Readable.from(["hello world\n"]),
          ETag: `"${sourceETag}"`,
        };
      }

      if (command instanceof DeleteObjectCommand) {
        state.deleteCount += 1;
        state.sourcePresent = false;
        return {};
      }

      throw new Error(`Unexpected command: ${command.constructor.name}`);
    },
  };

  class UploadClass {
    constructor({ params }) {
      this.params = params;
    }

    async done() {
      for await (const _chunk of this.params.Body) {
        // Consume the gzip stream exactly as the real upload would.
      }

      state.uploadCount += 1;
      state.destinationMetadata = this.params.Metadata;
      assert.equal(this.params.Bucket, bucket);
      assert.equal(this.params.Key, destinationKey);
    }
  }

  return {
    state,
    handler: createHandler({ s3Client, UploadClass }),
  };
}

test("normal processing uploads once, records source identity, and deletes source", async () => {
  const { handler, state } = createS3Harness();
  const response = await handler({
    Records: [sqsRecord("first")],
  });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.uploadCount, 1);
  assert.equal(state.deleteCount, 1);
  assert.deepEqual(state.destinationMetadata, expectedMetadata());
});

test("duplicate delivery uses matching destination metadata without recompressing", async () => {
  const { handler, state } = createS3Harness();

  await handler({ Records: [sqsRecord("first")] });
  const duplicateResponse = await handler({
    Records: [sqsRecord("duplicate")],
  });

  assert.deepEqual(duplicateResponse, { batchItemFailures: [] });
  assert.equal(state.uploadCount, 1);
  assert.equal(state.deleteCount, 2);
});

test("missing source succeeds when matching destination proves prior processing", async () => {
  const { handler, state } = createS3Harness({
    sourcePresent: false,
    destinationMetadata: expectedMetadata(),
  });

  const response = await handler({
    Records: [sqsRecord("already-deleted")],
  });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.uploadCount, 0);
  assert.equal(state.deleteCount, 1);
});

test("mismatched destination metadata is a genuine failure", async () => {
  const { handler, state } = createS3Harness({
    destinationMetadata: expectedMetadata({ eTag: "different-etag" }),
  });

  const response = await handler({
    Records: [sqsRecord("conflict")],
  });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "conflict" }],
  });
  assert.equal(state.uploadCount, 0);
  assert.equal(state.deleteCount, 0);
});

test("destination AccessDenied remains a genuine failure", async () => {
  const { handler } = createS3Harness({
    denyDestinationHead: true,
  });

  const response = await handler({
    Records: [sqsRecord("denied")],
  });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "denied" }],
  });
});

test("mixed SQS batch reports only the genuine failure", async () => {
  const { handler } = createS3Harness({
    sourcePresent: false,
    destinationMetadata: expectedMetadata(),
  });

  const response = await handler({
    Records: [
      sqsRecord("successful-duplicate"),
      sqsRecord(
        "genuine-failure",
        s3Record({ key: "incoming/other.txt", eTag: "other-etag" })
      ),
    ],
  });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "genuine-failure" }],
  });
});
