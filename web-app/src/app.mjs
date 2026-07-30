import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import { createFilesRouter } from "./routes/files.mjs";
import {
  errorHandler,
  notFoundHandler,
} from "./middleware/error-handler.mjs";

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const publicDirectory = path.resolve(currentDirectory, "../public");

export function createApp({ config, fileService }) {
  const app = express();
  app.disable("x-powered-by");

  app.get("/health", (request, response) => {
    response.json({ status: "ok" });
  });
  app.use("/api", createFilesRouter({ config, fileService }));
  app.use(express.static(publicDirectory, {
    extensions: ["html"],
    index: "index.html",
  }));
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
