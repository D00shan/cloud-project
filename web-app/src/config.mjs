const INTEGER_RULES = {
  PORT: { min: 1, max: 65535, defaultValue: 3000 },
  MAX_UPLOAD_BYTES: { min: 1, max: 1024 * 1024 * 1024, defaultValue: 26214400 },
  DELAYED_AFTER_SECONDS: { min: 1, max: 604800, defaultValue: 300 },
  DOWNLOAD_URL_TTL_SECONDS: { min: 1, max: 3600, defaultValue: 60 },
  FILE_LIST_LIMIT: { min: 1, max: 100, defaultValue: 20 },
  POLL_INTERVAL_MS: { min: 1000, max: 300000, defaultValue: 5000 },
};

function requiredString(environment, name) {
  const value = String(environment[name] ?? "").trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function integerValue(environment, name) {
  const rule = INTEGER_RULES[name];
  const raw = environment[name];
  const value = raw === undefined || raw === ""
    ? rule.defaultValue
    : Number(raw);

  if (!Number.isSafeInteger(value) || value < rule.min || value > rule.max) {
    throw new Error(
      `${name} must be an integer between ${rule.min} and ${rule.max}.`,
    );
  }
  return value;
}

export function normalizePrefix(value, name) {
  const normalized = String(value ?? "")
    .trim()
    .replace(/^\/+|\/+$/g, "");

  if (!normalized || normalized.includes("\\") || normalized.includes("..")) {
    throw new Error(`${name} must be a safe, non-empty S3 key prefix.`);
  }
  return `${normalized}/`;
}

export function createConfig(environment = process.env) {
  const region = requiredString(environment, "AWS_REGION");
  const bucketName = requiredString(environment, "S3_BUCKET_NAME");
  const incomingPrefix = normalizePrefix(
    environment.INCOMING_PREFIX ?? "incoming/",
    "INCOMING_PREFIX",
  );
  const compressedPrefix = normalizePrefix(
    environment.COMPRESSED_PREFIX ?? "compressed/",
    "COMPRESSED_PREFIX",
  );

  if (incomingPrefix === compressedPrefix) {
    throw new Error("INCOMING_PREFIX and COMPRESSED_PREFIX must be different.");
  }
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucketName)) {
    throw new Error("S3_BUCKET_NAME is not a valid S3 bucket name.");
  }

  return Object.freeze({
    port: integerValue(environment, "PORT"),
    awsRegion: region,
    bucketName,
    incomingPrefix,
    compressedPrefix,
    maxUploadBytes: integerValue(environment, "MAX_UPLOAD_BYTES"),
    delayedAfterSeconds: integerValue(environment, "DELAYED_AFTER_SECONDS"),
    downloadUrlTtlSeconds: integerValue(
      environment,
      "DOWNLOAD_URL_TTL_SECONDS",
    ),
    fileListLimit: integerValue(environment, "FILE_LIST_LIMIT"),
    pollIntervalMs: integerValue(environment, "POLL_INTERVAL_MS"),
  });
}
