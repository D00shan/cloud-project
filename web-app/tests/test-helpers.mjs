import { createConfig } from "../src/config.mjs";

export function testConfig(overrides = {}) {
  return {
    ...createConfig({
      PORT: "3000",
      AWS_REGION: "us-east-1",
      S3_BUCKET_NAME: "portable-web-test-bucket",
      INCOMING_PREFIX: "incoming/",
      COMPRESSED_PREFIX: "compressed/",
      MAX_UPLOAD_BYTES: "1024",
      DELAYED_AFTER_SECONDS: "300",
      DOWNLOAD_URL_TTL_SECONDS: "60",
      FILE_LIST_LIMIT: "20",
      POLL_INTERVAL_MS: "5000",
    }),
    ...overrides,
  };
}

export function commandClient(handler) {
  const commands = [];
  return {
    commands,
    async send(command) {
      commands.push(command);
      return handler(command, commands);
    },
  };
}
