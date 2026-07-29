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
const sourceETag = "AbC123";
const etagCondition = `"${sourceETag}"`;

function notFound(name = "NotFound") {
  return Object.assign(new Error(name), {
    name,
    $metadata: { httpStatusCode: 404 },
  });
}

function preconditionFailed() {
  return Object.assign(new Error("PreconditionFailed"), {
    name: "PreconditionFailed",
    $metadata: { httpStatusCode: 412 },
  });
}

function accessDenied() {
  return Object.assign(new Error("AccessDenied"), {
    name: "AccessDenied",
    $metadata: { httpStatusCode: 403 },
  });
}

function s3Record({ key = sourceKey, eTag = sourceETag, versionId } = {}) {
  return {
    eventSource: "aws:s3",
    eventName: "ObjectCreated:Put",
    s3: {
      bucket: { name: bucket },
      object: {
        key: encodeURIComponent(key).replace(/%20/g, "+"),
        eTag,
        size: 12,
        ...(versionId ? { versionId } : {}),
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

function metadataFor({
  key = sourceKey,
  eTag = sourceETag,
  versionId,
} = {}) {
  return {
    "source-bucket": bucket,
    "source-key": encodeURIComponent(key),
    "source-etag": eTag,
    ...(versionId
      ? { "source-version-id": encodeURIComponent(versionId) }
      : {}),
  };
}

function compressedKeyFor(key) {
  return `compressed/${key.slice("incoming/".length)}.gz`;
}

function createS3Harness({
  sources = {
    [sourceKey]: { present: true, eTag: sourceETag },
  },
  destinations = {},
  getErrors = {},
  deleteErrors = {},
  headErrors = {},
} = {}) {
  const state = {
    sources: structuredClone(sources),
    destinations: structuredClone(destinations),
    getInputs: [],
    deleteInputs: [],
    headInputs: [],
    uploadInputs: [],
  };

  const s3Client = {
    async send(command) {
      if (command instanceof HeadObjectCommand) {
        state.headInputs.push(structuredClone(command.input));
        if (headErrors[command.input.Key]) {
          throw headErrors[command.input.Key];
        }
        const metadata = state.destinations[command.input.Key];
        if (!metadata) {
          throw notFound();
        }
        return { Metadata: metadata };
      }

      if (command instanceof GetObjectCommand) {
        state.getInputs.push(structuredClone(command.input));
        if (getErrors[command.input.Key]) {
          throw getErrors[command.input.Key];
        }
        const source = state.sources[command.input.Key];
        if (!source?.present) {
          throw notFound("NoSuchKey");
        }
        return {
          Body: Readable.from(["hello world\n"]),
          ETag: `"${source.eTag}"`,
        };
      }

      if (command instanceof DeleteObjectCommand) {
        state.deleteInputs.push(structuredClone(command.input));
        if (deleteErrors[command.input.Key]) {
          throw deleteErrors[command.input.Key];
        }
        const source = state.sources[command.input.Key];
        if (!source?.present) {
          throw notFound("NoSuchKey");
        }
        source.present = false;
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
      state.uploadInputs.push({
        Bucket: this.params.Bucket,
        Key: this.params.Key,
        Metadata: structuredClone(this.params.Metadata),
      });
      state.destinations[this.params.Key] = structuredClone(
        this.params.Metadata
      );
    }
  }

  return {
    state,
    handler: createHandler({ s3Client, UploadClass }),
  };
}

test("normal processing uses conditional read/delete and source metadata", async () => {
  const { handler, state } = createS3Harness();
  const response = await handler({ Records: [sqsRecord("first")] });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.deepEqual(state.getInputs, [
    { Bucket: bucket, Key: sourceKey, IfMatch: etagCondition },
  ]);
  assert.deepEqual(state.deleteInputs, [
    { Bucket: bucket, Key: sourceKey, IfMatch: etagCondition },
  ]);
  assert.equal(state.uploadInputs.length, 1);
  assert.deepEqual(state.uploadInputs[0].Metadata, metadataFor());
  assert.equal(state.sources[sourceKey].present, false);
});

test("completed duplicate conditionally deletes without a second upload", async () => {
  const { handler, state } = createS3Harness({
    destinations: { [destinationKey]: metadataFor() },
  });
  const response = await handler({ Records: [sqsRecord("duplicate")] });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.uploadInputs.length, 0);
  assert.equal(state.getInputs.length, 0);
  assert.deepEqual(state.deleteInputs[0], {
    Bucket: bucket,
    Key: sourceKey,
    IfMatch: etagCondition,
  });
});

test("already absent source succeeds with matching destination metadata", async () => {
  const { handler, state } = createS3Harness({
    sources: { [sourceKey]: { present: false, eTag: sourceETag } },
    destinations: { [destinationKey]: metadataFor() },
  });
  const response = await handler({ Records: [sqsRecord("already-absent")] });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.uploadInputs.length, 0);
  assert.equal(state.deleteInputs.length, 1);
});

test("stale event before download leaves replacement untouched", async () => {
  const { handler, state } = createS3Harness({
    sources: { [sourceKey]: { present: true, eTag: "ReplacementETag" } },
    getErrors: { [sourceKey]: preconditionFailed() },
  });
  const response = await handler({ Records: [sqsRecord("stale")] });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.getInputs[0].IfMatch, etagCondition);
  assert.equal(state.deleteInputs.length, 0);
  assert.equal(state.uploadInputs.length, 0);
  assert.equal(state.sources[sourceKey].present, true);
});

test("replacement after download survives conditional delete failure", async () => {
  const { handler, state } = createS3Harness({
    deleteErrors: { [sourceKey]: preconditionFailed() },
  });
  const response = await handler({ Records: [sqsRecord("replaced-late")] });

  assert.deepEqual(response, { batchItemFailures: [] });
  assert.equal(state.uploadInputs.length, 1);
  assert.equal(state.deleteInputs[0].IfMatch, etagCondition);
  assert.equal(state.sources[sourceKey].present, true);
});

test("mismatched destination metadata is not overwritten", async () => {
  const { handler, state } = createS3Harness({
    destinations: {
      [destinationKey]: metadataFor({ eTag: "DifferentETag" }),
    },
  });
  const response = await handler({ Records: [sqsRecord("conflict")] });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "conflict" }],
  });
  assert.equal(state.uploadInputs.length, 0);
  assert.equal(state.deleteInputs.length, 0);
});

test("conditional deletion AccessDenied is a batch failure", async () => {
  const { handler, state } = createS3Harness({
    destinations: { [destinationKey]: metadataFor() },
    deleteErrors: { [sourceKey]: accessDenied() },
  });
  const response = await handler({ Records: [sqsRecord("delete-denied")] });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "delete-denied" }],
  });
  assert.equal(state.deleteInputs[0].IfMatch, etagCondition);
});

test("mixed batch reports only the genuine destination conflict", async () => {
  const conflictKey = "incoming/conflict.txt";
  const { handler } = createS3Harness({
    sources: {
      [sourceKey]: { present: true, eTag: "ReplacementETag" },
      [conflictKey]: { present: true, eTag: "ConflictETag" },
    },
    destinations: {
      [compressedKeyFor(conflictKey)]: metadataFor({
        key: conflictKey,
        eTag: "OtherETag",
      }),
    },
    getErrors: { [sourceKey]: preconditionFailed() },
  });

  const response = await handler({
    Records: [
      sqsRecord("successful-stale"),
      sqsRecord(
        "genuine-conflict",
        s3Record({ key: conflictKey, eTag: "ConflictETag" })
      ),
    ],
  });

  assert.deepEqual(response, {
    batchItemFailures: [{ itemIdentifier: "genuine-conflict" }],
  });
});
