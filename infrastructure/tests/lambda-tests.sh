#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
PROJECT_ROOT="$(cd -- "$INFRASTRUCTURE_DIR/.." && pwd)"
STAGING_DIR="$INFRASTRUCTURE_DIR/build/lambda-package/staging"

"$INFRASTRUCTURE_DIR/package-lambda.sh"

cp \
  "$PROJECT_ROOT/lambdas/compression-handler/index.test.mjs" \
  "$STAGING_DIR/index.test.mjs"

(
  cd "$STAGING_DIR"
  # The test module uses node:test directly. Running it as the entry point
  # preserves individual subtest reporting on all supported Node versions.
  node index.test.mjs
)
