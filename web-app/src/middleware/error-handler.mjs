import multer from "multer";

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

export function notFoundHandler(request, response) {
  response.status(404).json({ error: "Route not found." });
}

export function errorHandler(error, request, response, next) {
  if (response.headersSent) {
    next(error);
    return;
  }

  let status = error instanceof HttpError ? error.status : 500;
  let message = error instanceof HttpError
    ? error.message
    : "An unexpected server error occurred.";

  if (error instanceof multer.MulterError) {
    status = error.code === "LIMIT_FILE_SIZE" ? 413 : 400;
    message = error.code === "LIMIT_FILE_SIZE"
      ? "The selected file exceeds the maximum upload size."
      : "The upload request is invalid.";
  }

  if (status >= 500) {
    console.error("Request failed", {
      method: request.method,
      path: request.path,
      error: error?.name ?? "Error",
    });
  }

  response.status(status).json({ error: message });
}
