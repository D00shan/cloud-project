#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
  pwd
)"

"$SCRIPT_DIR/infrastructure/tests/phase3-safety-tests.sh"
"$SCRIPT_DIR/infrastructure/tests/lambda-tests.sh"
"$SCRIPT_DIR/infrastructure/tests/phase4-validation-tests.sh"
"$SCRIPT_DIR/infrastructure/tests/portability-audit-tests.sh"
