import express from "express";
import multer from "multer";
import { HttpError } from "../middleware/error-handler.mjs";

export function createFilesRouter({ config, fileService }) {
  const router = express.Router();
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.maxUploadBytes, files: 1 },
  });

  router.post("/uploads", upload.single("file"), async (request, response) => {
    if (!request.file) {
      throw new HttpError(400, "Choose one file to upload.");
    }
    const result = await fileService.uploadFile(request.file);
    response.status(202).json(result);
  });

  router.get("/files", async (request, response) => {
    let limit = config.fileListLimit;
    if (request.query.limit !== undefined) {
      limit = Number(request.query.limit);
      if (
        !Number.isSafeInteger(limit) ||
        limit < 1 ||
        limit > config.fileListLimit
      ) {
        throw new HttpError(
          400,
          `limit must be an integer from 1 to ${config.fileListLimit}.`,
        );
      }
    }
    response.json({
      files: await fileService.listFiles(limit),
      pollIntervalMs: config.pollIntervalMs,
    });
  });

  router.post(
    "/files/download-url",
    express.json({ limit: "4kb" }),
    async (request, response) => {
      const key = request.body?.compressedKey;
      if (typeof key !== "string") {
        throw new HttpError(400, "A compressed file key is required.");
      }
      const url = await fileService.createDownloadUrl(key);
      response.json({ url, expiresIn: config.downloadUrlTtlSeconds });
    },
  );

  return router;
}
