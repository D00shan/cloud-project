#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOURCE_DIR="$PROJECT_ROOT/lambdas/compression-handler"
BUILD_DIR="$SCRIPT_DIR/build/lambda-package"
STAGING_DIR="$BUILD_DIR/staging"
ZIP_FILE="$BUILD_DIR/compression-handler.zip"

for command_name in npm zip unzip; do
  require_command "$command_name"
done

for source_file in index.mjs package.json package-lock.json; do
  [[ -f "$SOURCE_DIR/$source_file" ]] \
    || die "Required Lambda source file is missing: $SOURCE_DIR/$source_file"
done

[[ "$BUILD_DIR" == "$SCRIPT_DIR/build/lambda-package" ]] \
  || die "Refusing to clean unexpected package build directory: $BUILD_DIR"

rm -rf -- "$BUILD_DIR"
mkdir -p "$STAGING_DIR"

cp \
  "$SOURCE_DIR/index.mjs" \
  "$SOURCE_DIR/package.json" \
  "$SOURCE_DIR/package-lock.json" \
  "$STAGING_DIR/"

log "Installing production Lambda dependencies with npm ci..."

(
  cd "$STAGING_DIR"
  npm ci --omit=dev
)

[[ -d "$STAGING_DIR/node_modules" ]] \
  || die "npm ci did not create the required node_modules directory."

(
  cd "$STAGING_DIR"
  zip -qr "$ZIP_FILE" index.mjs package.json package-lock.json node_modules
)

[[ -f "$ZIP_FILE" ]] \
  || die "Lambda deployment ZIP was not created: $ZIP_FILE"

zip_entries="$(unzip -Z1 "$ZIP_FILE")"

for required_entry in index.mjs package.json package-lock.json; do
  grep -Fxq "$required_entry" <<<"$zip_entries" \
    || die "Lambda ZIP is missing required root entry: $required_entry"
done

grep -Eq '^node_modules/' <<<"$zip_entries" \
  || die "Lambda ZIP does not contain node_modules at the ZIP root."

if grep -Eq '^compression-handler/' <<<"$zip_entries"; then
  die "Lambda ZIP incorrectly wraps files in a compression-handler directory."
fi

log "Lambda package created and validated: $ZIP_FILE"
