import assert from "node:assert/strict";
import { test } from "node:test";
import request from "supertest";
import { createApp } from "../src/app.mjs";
import { testConfig } from "./test-helpers.mjs";

function appWith(service) {
  const config = testConfig();
  return createApp({
    config,
    fileService: service,
  });
}

test("files endpoint returns normalized files and polling configuration", async () => {
  const expected = [{
    uploadId: "one",
    originalName: "report.pdf",
    status: "processing",
    uploadedAt: "2026-07-30T06:15:12.000Z",
    compressedSize: null,
    compressedKey: null,
  }];
  const app = appWith({
    listFiles: async () => expected,
    uploadFile: async () => {},
    createDownloadUrl: async () => "",
  });
  const response = await request(app).get("/api/files");
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, {
    files: expected,
    pollIntervalMs: 5000,
  });
});

test("download endpoint delegates validated signing and returns its TTL", async () => {
  let receivedKey;
  const app = appWith({
    listFiles: async () => [],
    uploadFile: async () => {},
    createDownloadUrl: async (key) => {
      receivedKey = key;
      return "https://download.example.invalid/signed";
    },
  });
  const response = await request(app)
    .post("/api/files/download-url")
    .send({ compressedKey: "compressed/id/file.gz" });
  assert.equal(response.status, 200);
  assert.equal(receivedKey, "compressed/id/file.gz");
  assert.deepEqual(response.body, {
    url: "https://download.example.invalid/signed",
    expiresIn: 60,
  });
});
