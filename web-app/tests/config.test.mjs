import assert from "node:assert/strict";
import { test } from "node:test";
import { createConfig } from "../src/config.mjs";

const validEnvironment = {
  AWS_REGION: "us-east-1",
  S3_BUCKET_NAME: "portable-web-test-bucket",
};

test("configuration normalizes prefixes to one trailing slash", () => {
  const config = createConfig({
    ...validEnvironment,
    INCOMING_PREFIX: "/incoming",
    COMPRESSED_PREFIX: "compressed///",
  });
  assert.equal(config.incomingPrefix, "incoming/");
  assert.equal(config.compressedPrefix, "compressed/");
});

test("malformed or missing configuration fails clearly", () => {
  assert.throws(() => createConfig({}), /AWS_REGION/);
  assert.throws(
    () => createConfig({ ...validEnvironment, MAX_UPLOAD_BYTES: "many" }),
    /MAX_UPLOAD_BYTES must be an integer/,
  );
  assert.throws(
    () => createConfig({
      ...validEnvironment,
      INCOMING_PREFIX: "same",
      COMPRESSED_PREFIX: "same/",
    }),
    /must be different/,
  );
});
