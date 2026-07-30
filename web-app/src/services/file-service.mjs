import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  GetObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { HttpError } from "../middleware/error-handler.mjs";

const UPLOAD_ID_PATTERN =
  /^\d{8}T\d{6}Z_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function sanitizeFilename(originalName) {
  const withoutControls = String(originalName ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[\\/]+/g, "_");
  const basename = path.basename(withoutControls)
    .replace(/\.\.+/g, "_")
    .replace(/[<>:"|?*]/g, "_")
    .trim()
    .replace(/^[.\s]+|[.\s]+$/g, "");

  const safeName = basename || "upload";
  return safeName.length <= 180 ? safeName : safeName.slice(0, 180);
}

export function createUploadId(now = new Date(), uuidFactory = randomUUID) {
  const timestamp = now.toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
  return `${timestamp}_${uuidFactory()}`;
}

export function createUploadKey(config, originalName, options = {}) {
  const uploadId = createUploadId(options.now, options.uuidFactory);
  const safeName = sanitizeFilename(originalName);
  return {
    uploadId,
    safeName,
    key: `${config.incomingPrefix}${uploadId}/${safeName}`,
  };
}

function objectTime(object) {
  if (!object) return 0;
  const milliseconds = new Date(object.LastModified ?? 0).getTime();
  return Number.isFinite(milliseconds) ? milliseconds : 0;
}

function parseRelativeKey(relativeKey) {
  const slashIndex = relativeKey.indexOf("/");
  if (slashIndex <= 0 || slashIndex === relativeKey.length - 1) {
    return null;
  }
  const uploadId = relativeKey.slice(0, slashIndex);
  if (!UPLOAD_ID_PATTERN.test(uploadId)) {
    return null;
  }
  return {
    uploadId,
    originalName: relativeKey.slice(slashIndex + 1),
  };
}

export function isAllowedCompressedKey(config, key) {
  if (typeof key !== "string" || !key.startsWith(config.compressedPrefix)) {
    return false;
  }
  if (key.includes("\0") || key.includes("\\") || key.includes("..")) {
    return false;
  }
  const relative = key.slice(config.compressedPrefix.length);
  if (!relative.endsWith(".gz")) {
    return false;
  }
  return parseRelativeKey(relative.slice(0, -3)) !== null;
}

async function listAll(client, bucketName, prefix) {
  const objects = [];
  let continuationToken;
  do {
    const result = await client.send(new ListObjectsV2Command({
      Bucket: bucketName,
      Prefix: prefix,
      ContinuationToken: continuationToken,
    }));
    objects.push(...(result.Contents ?? []));
    continuationToken = result.IsTruncated
      ? result.NextContinuationToken
      : undefined;
    if (result.IsTruncated && !continuationToken) {
      throw new Error("S3 returned a truncated listing without a continuation token.");
    }
  } while (continuationToken);
  return objects;
}

export function createFileService({
  config,
  s3Client,
  signUrl = getSignedUrl,
  now = () => new Date(),
  uuidFactory = randomUUID,
}) {
  return {
    async uploadFile(file) {
      if (!file?.buffer) {
        throw new HttpError(400, "Choose one file to upload.");
      }
      if (file.size === 0 || file.buffer.length === 0) {
        throw new HttpError(400, "Empty files cannot be uploaded.");
      }
      if (file.size > config.maxUploadBytes) {
        throw new HttpError(413, "The selected file exceeds the maximum upload size.");
      }

      const generated = createUploadKey(config, file.originalname, {
        now: now(),
        uuidFactory,
      });
      await s3Client.send(new PutObjectCommand({
        Bucket: config.bucketName,
        Key: generated.key,
        Body: file.buffer,
        ContentLength: file.size,
        ContentType: file.mimetype || "application/octet-stream",
      }));

      return {
        uploadId: generated.uploadId,
        originalName: generated.safeName,
        status: "processing",
      };
    },

    async listFiles(limit = config.fileListLimit) {
      const [incomingObjects, compressedObjects] = await Promise.all([
        listAll(s3Client, config.bucketName, config.incomingPrefix),
        listAll(s3Client, config.bucketName, config.compressedPrefix),
      ]);
      const incomingByRelative = new Map();
      const compressedByRelative = new Map();

      for (const object of incomingObjects) {
        const relative = object.Key?.slice(config.incomingPrefix.length);
        if (relative && parseRelativeKey(relative)) {
          incomingByRelative.set(relative, object);
        }
      }
      for (const object of compressedObjects) {
        const relativeWithGzip = object.Key?.slice(config.compressedPrefix.length);
        if (!relativeWithGzip?.endsWith(".gz")) continue;
        const relative = relativeWithGzip.slice(0, -3);
        if (parseRelativeKey(relative)) {
          compressedByRelative.set(relative, object);
        }
      }

      const currentTime = now().getTime();
      const delayedAfterMs = config.delayedAfterSeconds * 1000;
      const relativeKeys = new Set([
        ...incomingByRelative.keys(),
        ...compressedByRelative.keys(),
      ]);
      const files = [];

      for (const relative of relativeKeys) {
        const parsed = parseRelativeKey(relative);
        const incoming = incomingByRelative.get(relative);
        const compressed = compressedByRelative.get(relative);
        const sourceTimestamp = objectTime(incoming);
        const outputTimestamp = objectTime(compressed);
        const ready = Boolean(compressed);
        const delayed = !ready && incoming &&
          currentTime - sourceTimestamp > delayedAfterMs;

        files.push({
          uploadId: parsed.uploadId,
          originalName: parsed.originalName,
          status: ready ? "ready" : delayed ? "delayed" : "processing",
          uploadedAt: new Date(sourceTimestamp || outputTimestamp).toISOString(),
          compressedSize: ready ? (compressed.Size ?? 0) : null,
          compressedKey: ready ? compressed.Key : null,
          _sortTime: Math.max(sourceTimestamp, outputTimestamp),
        });
      }

      return files
        .sort((left, right) => right._sortTime - left._sortTime)
        .slice(0, limit)
        .map(({ _sortTime, ...file }) => file);
    },

    async createDownloadUrl(key) {
      if (!isAllowedCompressedKey(config, key)) {
        throw new HttpError(400, "The requested compressed file key is invalid.");
      }

      try {
        await s3Client.send(new HeadObjectCommand({
          Bucket: config.bucketName,
          Key: key,
        }));
      } catch (error) {
        if (
          error?.name === "NotFound" ||
          error?.name === "NoSuchKey" ||
          error?.$metadata?.httpStatusCode === 404
        ) {
          throw new HttpError(404, "The compressed file is not available.");
        }
        throw error;
      }

      const command = new GetObjectCommand({
        Bucket: config.bucketName,
        Key: key,
        ResponseContentDisposition: "attachment",
      });
      return signUrl(s3Client, command, {
        expiresIn: config.downloadUrlTtlSeconds,
      });
    },
  };
}
