import assert from "node:assert/strict";
import { test } from "node:test";
import request from "supertest";
import { createApp } from "../src/app.mjs";
import { createFileService } from "../src/services/file-service.mjs";
import {
  commandClient,
  testConfig,
} from "./test-helpers.mjs";

function uploadApp(configOverrides = {}, serviceOverrides = {}) {
  const config = testConfig(configOverrides);
  const client = commandClient(() => ({}));
  const fileService = createFileService({
    config,
    s3Client: client,
    now: () => new Date("2026-07-30T06:15:12.000Z"),
    uuidFactory: () => "11111111-1111-4111-8111-111111111111",
    ...serviceOverrides,
  });
  return { app: createApp({ config, fileService }), client };
}

test("upload endpoint stores one file and returns 202", async () => {
  const { app, client } = uploadApp();
  const response = await request(app)
    .post("/api/uploads")
    .attach("file", Buffer.from("hello"), "report.pdf");
  const result = response.body;

  assert.equal(response.status, 202);
  assert.equal(result.status, "processing");
  assert.equal(result.originalName, "report.pdf");
  assert.match(result.uploadId, /^20260730T061512Z_/);
  assert.equal(client.commands[0].input.Key, `incoming/${result.uploadId}/report.pdf`);
});

test("missing and empty files are rejected", async () => {
  const { app } = uploadApp();
  const missing = await request(app).post("/api/uploads");
  assert.equal(missing.status, 400);

  const empty = await request(app)
    .post("/api/uploads")
    .attach("file", Buffer.alloc(0), "empty.txt");
  assert.equal(empty.status, 400);
  assert.match(empty.body.error, /Empty files/);
});

test("oversized files are rejected by multipart limits", async () => {
  const { app } = uploadApp({ maxUploadBytes: 4 });
  const response = await request(app)
    .post("/api/uploads")
    .attach("file", Buffer.from("too large"), "large.txt");
  assert.equal(response.status, 413);
  assert.match(response.body.error, /maximum upload size/);
});

test("unexpected backend failures return safe JSON without stack traces", async () => {
  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    const config = testConfig();
    const fileService = {
      uploadFile: async () => {
        throw new Error("internal credential provider detail");
      },
      listFiles: async () => [],
      createDownloadUrl: async () => "",
    };
    const app = createApp({ config, fileService });
    const response = await request(app)
      .post("/api/uploads")
      .attach("file", Buffer.from("hello"), "file.txt");
    const result = response.body;

    assert.equal(response.status, 500);
    assert.deepEqual(result, { error: "An unexpected server error occurred." });
    assert.equal(JSON.stringify(result).includes("credential"), false);
  } finally {
    console.error = originalConsoleError;
  }
});
