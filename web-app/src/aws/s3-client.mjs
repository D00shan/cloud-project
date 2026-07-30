import { S3Client } from "@aws-sdk/client-s3";

export function createS3Client(config) {
  return new S3Client({ region: config.awsRegion });
}
