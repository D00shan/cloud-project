import {
  S3Client,
  GetObjectCommand,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";

import { Upload } from "@aws-sdk/lib-storage";
import { pipeline } from "node:stream/promises";
import { createGzip } from "node:zlib";

const s3 = new S3Client({});

/**
 * Decode the URL-encoded key supplied by an S3 event notification.
 *
 * S3 represents spaces as "+" in event notification object keys,
 * so "+" must first be converted to a space before decodeURIComponent().
 */
function decodeS3Key(encodedKey) {
  return decodeURIComponent(encodedKey.replace(/\+/g, " "));
}

async function compressObject(s3Record) {
  const bucketName = s3Record?.s3?.bucket?.name;
  const encodedKey = s3Record?.s3?.object?.key;

  if (!bucketName || !encodedKey) {
    throw new Error(
      "The S3 event must contain s3.bucket.name and s3.object.key."
    );
  }

  const key = decodeS3Key(encodedKey);

  console.log("Processing S3 event", {
    eventName: s3Record.eventName,
    eventTime: s3Record.eventTime,
    bucketName,
    key,
    objectSize: s3Record.s3.object.size,
    eTag: s3Record.s3.object.eTag,
    sequencer: s3Record.s3.object.sequencer,
  });

  if (!key.startsWith("incoming/")) {
    console.log("Skipping object outside incoming/", {
      bucketName,
      key,
    });

    return {
      skipped: true,
      bucket: bucketName,
      sourceKey: key,
      reason: "Object is outside incoming/",
    };
  }

  const fileName = key.slice("incoming/".length);

  if (!fileName) {
    throw new Error(`Source key does not include a file name: ${key}`);
  }

  // Avoid accidentally processing directory placeholder objects.
  if (key.endsWith("/")) {
    console.log("Skipping directory placeholder object", {
      bucketName,
      key,
    });

    return {
      skipped: true,
      bucket: bucketName,
      sourceKey: key,
      reason: "Directory placeholder",
    };
  }

  const compressedKey = `compressed/${fileName}.gz`;

  console.log("Downloading source object", {
    bucketName,
    key,
    compressedKey,
  });

  const response = await s3.send(
    new GetObjectCommand({
      Bucket: bucketName,
      Key: key,
    })
  );

  if (!response.Body) {
    throw new Error(`Object body is empty: s3://${bucketName}/${key}`);
  }

  console.log("Source object downloaded", {
    bucketName,
    key,
    versionId: response.VersionId ?? "versioning-disabled",
  });

  const gzipStream = createGzip();

  const upload = new Upload({
    client: s3,
    params: {
      Bucket: bucketName,
      Key: compressedKey,
      Body: gzipStream,
      ContentType: "application/gzip",
      Metadata: {
        "source-key": key,
      },
    },
    partSize: 5 * 1024 * 1024,
    queueSize: 2,
    leavePartsOnError: false,
  });

  await Promise.all([
    pipeline(response.Body, gzipStream),
    upload.done(),
  ]);

  console.log("Compressed upload completed", {
    bucketName,
    sourceKey: key,
    compressedKey,
  });

  const deleteParams = {
    Bucket: bucketName,
    Key: key,

    // Delete the exact source version when bucket versioning is enabled.
    ...(response.VersionId
      ? { VersionId: response.VersionId }
      : {}),
  };

  console.log("Source file deletion started", deleteParams);

  const deleteResult = await s3.send(
    new DeleteObjectCommand(deleteParams)
  );

  console.log("Source file deletion completed", {
    bucketName,
    deletedSourceKey: key,
    deleteMarker: deleteResult.DeleteMarker,
    deletedVersionId: deleteResult.VersionId,
  });

  return {
    skipped: false,
    bucket: bucketName,
    deletedSourceKey: key,
    deletedVersionId: response.VersionId,
    compressedKey,
  };
}

export const handler = async (event, context) => {
  console.log("File compression invocation started", {
    requestId: context?.awsRequestId,
    sqsRecordCount: event?.Records?.length ?? 0,
  });

  const batchItemFailures = [];
  const results = [];

  for (const sqsRecord of event?.Records ?? []) {
    try {
      console.log("Processing SQS message", {
        messageId: sqsRecord.messageId,
        eventSource: sqsRecord.eventSource,
      });

      const s3Message = JSON.parse(sqsRecord.body);

      /*
       * S3 can send an s3:TestEvent when the event notification
       * configuration is created. It does not use the normal
       * { Records: [...] } structure.
       */
      if (s3Message.Event === "s3:TestEvent") {
        console.log("Ignoring S3 test event", {
          messageId: sqsRecord.messageId,
          bucket: s3Message.Bucket,
        });

        continue;
      }

      if (!Array.isArray(s3Message.Records)) {
        throw new Error(
          "SQS message body does not contain an S3 Records array."
        );
      }

      for (const s3Record of s3Message.Records) {
        if (s3Record.eventSource !== "aws:s3") {
          console.log("Skipping non-S3 record", {
            eventSource: s3Record.eventSource,
          });

          continue;
        }

        if (!s3Record.eventName?.startsWith("ObjectCreated:")) {
          console.log("Skipping non-object-created event", {
            eventName: s3Record.eventName,
          });

          continue;
        }

        const result = await compressObject(s3Record);
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

      /*
       * Mark only this SQS message as failed.
       *
       * Lambda must have ReportBatchItemFailures enabled on the
       * SQS event source mapping for this response to take effect.
       */
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