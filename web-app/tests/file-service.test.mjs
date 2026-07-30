import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createFileService,
  createUploadKey,
  isAllowedCompressedKey,
  sanitizeFilename,
} from "../src/services/file-service.mjs";
import { commandClient, testConfig } from "./test-helpers.mjs";

const firstUuid = "11111111-1111-4111-8111-111111111111";
const secondUuid = "22222222-2222-4222-8222-222222222222";
const fixedDate = new Date("2026-07-30T06:15:12.000Z");

test("identical filenames receive unique upload keys", () => {
  const config = testConfig();
  const uuids = [firstUuid, secondUuid];
  const first = createUploadKey(config, "report.pdf", {
    now: fixedDate,
    uuidFactory: () => uuids.shift(),
  });
  const second = createUploadKey(config, "report.pdf", {
    now: fixedDate,
    uuidFactory: () => uuids.shift(),
  });

  assert.notEqual(first.key, second.key);
  assert.match(first.key, /^incoming\/20260730T061512Z_/);
  assert.ok(first.key.endsWith("/report.pdf"));
});

test("filenames are sanitized and traversal cannot escape the upload path", () => {
  assert.equal(sanitizeFilename("../folder\\bad\u0000:name.txt"), "__folder_bad_name.txt");
  const generated = createUploadKey(testConfig(), "../../secret.txt", {
    now: fixedDate,
    uuidFactory: () => firstUuid,
  });
  assert.ok(generated.key.startsWith(`incoming/${generated.uploadId}/`));
  assert.equal(generated.key.includes(".."), false);
  assert.equal(generated.key.split("/").length, 3);
});

test("incoming-only objects are processing and older objects are delayed", async () => {
  const now = new Date("2026-07-30T07:00:00.000Z");
  const recentKey = `incoming/20260730T065900Z_${firstUuid}/recent.txt`;
  const oldKey = `incoming/20260730T060000Z_${secondUuid}/old.txt`;
  const client = commandClient((command) => {
    if (command.input.Prefix === "incoming/") {
      return {
        Contents: [
          { Key: oldKey, LastModified: new Date("2026-07-30T06:00:00Z"), Size: 3 },
          { Key: recentKey, LastModified: new Date("2026-07-30T06:59:00Z"), Size: 4 },
        ],
      };
    }
    return { Contents: [] };
  });
  const service = createFileService({
    config: testConfig(),
    s3Client: client,
    now: () => now,
  });

  const files = await service.listFiles();
  assert.deepEqual(files.map((file) => file.status), ["processing", "delayed"]);
});

test("matching compressed objects are ready and results sort newest-first", async () => {
  const olderId = `20260730T060000Z_${firstUuid}`;
  const newerId = `20260730T070000Z_${secondUuid}`;
  const client = commandClient((command) => {
    if (command.input.Prefix === "incoming/") {
      return {
        Contents: [{
          Key: `incoming/${olderId}/old.txt`,
          LastModified: new Date("2026-07-30T06:00:00Z"),
        }],
      };
    }
    return {
      Contents: [
        {
          Key: `compressed/${olderId}/old.txt.gz`,
          LastModified: new Date("2026-07-30T06:01:00Z"),
          Size: 10,
        },
        {
          Key: `compressed/${newerId}/new.txt.gz`,
          LastModified: new Date("2026-07-30T07:01:00Z"),
          Size: 20,
        },
      ],
    };
  });
  const service = createFileService({
    config: testConfig(),
    s3Client: client,
    now: () => new Date("2026-07-30T07:02:00Z"),
  });

  const files = await service.listFiles();
  assert.deepEqual(files.map((file) => file.originalName), ["new.txt", "old.txt"]);
  assert.equal(files[0].status, "ready");
  assert.equal(files[0].compressedSize, 20);
});

test("download signing rejects incoming and arbitrary bucket keys", async () => {
  const config = testConfig();
  assert.equal(
    isAllowedCompressedKey(
      config,
      `compressed/20260730T061512Z_${firstUuid}/report.pdf.gz`,
    ),
    true,
  );
  assert.equal(
    isAllowedCompressedKey(
      config,
      `incoming/20260730T061512Z_${firstUuid}/report.pdf`,
    ),
    false,
  );
  assert.equal(isAllowedCompressedKey(config, "compressed/private.gz"), false);

  const service = createFileService({
    config,
    s3Client: commandClient(() => ({})),
  });
  await assert.rejects(
    service.createDownloadUrl("other/private-object"),
    /compressed file key is invalid/,
  );
});

test("valid existing compressed objects receive short-lived signed URLs", async () => {
  const key = `compressed/20260730T061512Z_${firstUuid}/report.pdf.gz`;
  let signingInput;
  const service = createFileService({
    config: testConfig(),
    s3Client: commandClient(() => ({})),
    signUrl: async (client, command, options) => {
      signingInput = { command, options };
      return "https://download.example.invalid/signed";
    },
  });

  const url = await service.createDownloadUrl(key);
  assert.equal(url, "https://download.example.invalid/signed");
  assert.equal(signingInput.command.input.Key, key);
  assert.equal(signingInput.options.expiresIn, 60);
});
