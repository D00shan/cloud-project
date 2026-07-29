import {
  S3Client,
  GetObjectCommand,
  DeleteObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";

import { Upload } from "@aws-sdk/lib-storage";
import { pipeline } from "node:stream/promises";
import { createGzip } from "node:zlib";

const s3 = new S3Client({});
const incomingPrefix = process.env.INCOMING_PREFIX ?? "incoming/";
const compressedPrefix = process.env.COMPRESSED_PREFIX ?? "compressed/";

function decodeS3Key(encodedKey) {
  return decodeURIComponent(encodedKey.replace(/\+/g, " "));
}

function normalizeETag(eTag) {
  return String(eTag ?? "")
    .trim()
    .replace(/^"+|"+$/g, "");
}

function formatETagCondition(eTag) {
  return `"${normalizeETag(eTag)}"`;
}

function isPreconditionFailedError(error) {
  return (
    error?.name === "PreconditionFailed" ||
    error?.Code === "PreconditionFailed" ||
    error?.$metadata?.httpStatusCode === 412
  );
}

function isNotFoundError(error) {
  return (
    error?.name === "NotFound" ||
    error?.name === "NoSuchKey" ||
    error?.Code === "NoSuchKey" ||
    error?.$metadata?.httpStatusCode === 404
  );
}

function sourceMetadata(bucketName, key, eTag, versionId) {
  return {
    "source-bucket": bucketName,
    "source-key": encodeURIComponent(key),
    "source-etag": normalizeETag(eTag),
    ...(versionId
      ? { "source-version-id": encodeURIComponent(versionId) }
      : {}),
  };
}

function metadataMatches(actualMetadata, expectedMetadata) {
  const normalizedActual = Object.fromEntries(
    Object.entries(actualMetadata ?? {}).map(([key, value]) => [
      key.toLowerCase(),
      String(value),
    ])
  );

  const actualEntries = Object.entries(normalizedActual).sort(([a], [b]) =>
    a.localeCompare(b)
  );
  const expectedEntries = Object.entries(expectedMetadata).sort(([a], [b]) =>
    a.localeCompare(b)
  );

  return JSON.stringify(actualEntries) === JSON.stringify(expectedEntries);
}

async function compressObject(s3Record, { s3Client, UploadClass }) {
  const bucketName = s3Record?.s3?.bucket?.name;
  const encodedKey = s3Record?.s3?.object?.key;
  const eventETag = normalizeETag(s3Record?.s3?.object?.eTag);
  const eventVersionId = s3Record?.s3?.object?.versionId;

  if (!bucketName || !encodedKey || !eventETag) {
    throw new Error(
      "The S3 event must contain s3.bucket.name, s3.object.key, and s3.object.eTag."
    );
  }

  const key = decodeS3Key(encodedKey);

  console.log("Processing S3 event", {
    eventName: s3Record.eventName,
    eventTime: s3Record.eventTime,
    bucketName,
    key,
    objectSize: s3Record.s3.object.size,
    eTag: eventETag,
    sequencer: s3Record.s3.object.sequencer,
  });

  if (!key.startsWith(incomingPrefix)) {
    return {
      skipped: true,
      bucket: bucketName,
      sourceKey: key,
      reason: `Object is outside ${incomingPrefix}`,
    };
  }

  const fileName = key.slice(incomingPrefix.length);

  if (!fileName) {
    throw new Error(`Source key does not include a file name: ${key}`);
  }

  if (key.endsWith("/")) {
    return {
      skipped: true,
      bucket: bucketName,
      sourceKey: key,
      reason: "Directory placeholder",
    };
  }

  const compressedKey = `${compressedPrefix}${fileName}.gz`;
  const expectedMetadata = sourceMetadata(
    bucketName,
    key,
    eventETag,
    eventVersionId
  );

  async function headCompressedObject() {
    try {
      return await s3Client.send(
        new HeadObjectCommand({
          Bucket: bucketName,
          Key: compressedKey,
        })
      );
    } catch (error) {
      if (isNotFoundError(error)) {
        return null;
      }
      throw error;
    }
  }

  async function deleteSourceObject() {
    try {
      return await s3Client.send(
        new DeleteObjectCommand({
          Bucket: bucketName,
          Key: key,
          IfMatch: formatETagCondition(eventETag),
        })
      );
    } catch (error) {
      if (isNotFoundError(error)) {
        return { alreadyAbsent: true };
      }

      if (isPreconditionFailedError(error)) {
        console.warn(
          "Source object changed before deletion; leaving replacement untouched",
          {
            bucketName,
            key,
            expectedETag: eventETag,
          }
        );

        return { sourceChanged: true };
      }

      throw error;
    }
  }

  const existingDestination = await headCompressedObject();

  if (existingDestination) {
    if (!metadataMatches(existingDestination.Metadata, expectedMetadata)) {
      throw new Error(
        `Compressed destination already exists for a different source object: s3://${bucketName}/${compressedKey}`
      );
    }

    await deleteSourceObject();

    return {
      skipped: false,
      alreadyProcessed: true,
      bucket: bucketName,
      deletedSourceKey: key,
      compressedKey,
    };
  }

  let response;

  try {
    response = await s3Client.send(
      new GetObjectCommand({
        Bucket: bucketName,
        Key: key,
        IfMatch: formatETagCondition(eventETag),
      })
    );
  } catch (error) {
    if (isPreconditionFailedError(error)) {
      console.warn("Skipping stale S3 event because the source object changed", {
        bucketName,
        key,
        expectedETag: eventETag,
      });

      return {
        skipped: true,
        bucket: bucketName,
        sourceKey: key,
        reason: "Source object changed after this event was emitted",
      };
    }

    if (!isNotFoundError(error)) {
      throw error;
    }

    const destinationAfterMissingSource = await headCompressedObject();

    if (
      destinationAfterMissingSource &&
      metadataMatches(
        destinationAfterMissingSource.Metadata,
        expectedMetadata
      )
    ) {
      return {
        skipped: false,
        alreadyProcessed: true,
        bucket: bucketName,
        deletedSourceKey: key,
        compressedKey,
      };
    }

    throw new Error(
      `Source object is missing and no matching compressed destination proves prior success: s3://${bucketName}/${key}`
    );
  }

  if (!response.Body) {
    throw new Error(`Object body is empty: s3://${bucketName}/${key}`);
  }

  const downloadedETag = normalizeETag(response.ETag ?? eventETag);

  if (downloadedETag !== eventETag) {
    throw new Error(
      `Downloaded source ETag does not match the S3 event for s3://${bucketName}/${key}`
    );
  }

  const gzipStream = createGzip();

  const upload = new UploadClass({
    client: s3Client,
    params: {
      Bucket: bucketName,
      Key: compressedKey,
      Body: gzipStream,
      ContentType: "application/gzip",
      Metadata: expectedMetadata,
    },
    partSize: 5 * 1024 * 1024,
    queueSize: 2,
    leavePartsOnError: false,
  });

  await Promise.all([
    pipeline(response.Body, gzipStream),
    upload.done(),
  ]);

  const deleteResult = await deleteSourceObject();

  return {
    skipped: false,
    alreadyProcessed: false,
    bucket: bucketName,
    deletedSourceKey: key,
    deletedVersionId: deleteResult.VersionId,
    compressedKey,
  };
}

export function createHandler({
  s3Client = s3,
  UploadClass = Upload,
} = {}) {
  return async (event, context) => {
    console.log("File compression invocation started", {
      requestId: context?.awsRequestId,
      sqsRecordCount: event?.Records?.length ?? 0,
    });

    const batchItemFailures = [];
    const results = [];

    for (const sqsRecord of event?.Records ?? []) {
      try {
        const s3Message = JSON.parse(sqsRecord.body);

        if (s3Message.Event === "s3:TestEvent") {
          continue;
        }

        if (!Array.isArray(s3Message.Records)) {
          throw new Error(
            "SQS message body does not contain an S3 Records array."
          );
        }

        for (const s3Record of s3Message.Records) {
          if (s3Record.eventSource !== "aws:s3") {
            continue;
          }

          if (!s3Record.eventName?.startsWith("ObjectCreated:")) {
            continue;
          }

          const result = await compressObject(s3Record, {
            s3Client,
            UploadClass,
          });
          results.push(result);
        }
      } catch (error) {
        console.error("SQS message processing failed", {
          messageId: sqsRecord.messageId,
          name: error?.name,
          message: error?.message,
          code: error?.Code ?? error?.code,
          stack: error?.stack,
        });

        batchItemFailures.push({
          itemIdentifier: sqsRecord.messageId,
        });
      }
    }

    console.log("File compression invocation completed", {
      successfulObjectCount: results.length,
      failedMessageCount: batchItemFailures.length,
      results,
    });

    return {
      batchItemFailures,
    };
  };
}

export const handler = createHandler();
