import "dotenv/config";
import { createApp } from "./app.mjs";
import { createS3Client } from "./aws/s3-client.mjs";
import { createConfig } from "./config.mjs";
import { createFileService } from "./services/file-service.mjs";

try {
  const config = createConfig();
  const s3Client = createS3Client(config);
  const fileService = createFileService({ config, s3Client });
  const app = createApp({ config, fileService });

  app.listen(config.port, () => {
    console.log(`File compression web app listening on port ${config.port}.`);
  });
} catch (error) {
  console.error(`Startup failed: ${error.message}`);
  process.exitCode = 1;
}
