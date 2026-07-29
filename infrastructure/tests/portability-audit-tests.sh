#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

for command_name in bash git grep jq tar; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { printf 'Required test command missing: %s\n' "$command_name" >&2; exit 1; }
done

SOURCE_SNAPSHOT="$TEST_ROOT/source"
mkdir -p "$SOURCE_SNAPSHOT"
(
  cd "$PROJECT_ROOT"
  tar \
    --exclude='.git' \
    --exclude='context' \
    --exclude='infrastructure/.env' \
    --exclude='infrastructure/build' \
    --exclude='infrastructure/state/deployment.json' \
    --exclude='lambdas/compression-handler/node_modules' \
    -cf - .
) | (cd "$SOURCE_SNAPSHOT" && tar -xf -)

new_repository() {
  local scenario="$1"
  REPOSITORY="$TEST_ROOT/$scenario"
  mkdir -p "$REPOSITORY"
  cp -a "$SOURCE_SNAPSHOT/." "$REPOSITORY/"
  (
    cd "$REPOSITORY"
    git init -q
    git config user.name "Portability Audit Test"
    git config user.email "audit-test@example.invalid"
    git add -A
  )
}

run_audit() {
  (
    cd "$REPOSITORY"
    ./infrastructure/tests/portability-audit.sh
  )
}

expect_pass() {
  local scenario="$1"
  if ! run_audit >"$TEST_ROOT/$scenario.out" 2>&1; then
    printf 'Expected audit pass for %s:\n' "$scenario" >&2
    cat "$TEST_ROOT/$scenario.out" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$scenario"
}

expect_failure() {
  local scenario="$1"
  local expected_message="$2"
  if run_audit >"$TEST_ROOT/$scenario.out" 2>&1; then
    printf 'Expected audit failure for %s.\n' "$scenario" >&2
    exit 1
  fi
  grep -Fq "$expected_message" "$TEST_ROOT/$scenario.out" || {
    printf 'Wrong audit failure for %s; expected %s:\n' \
      "$scenario" "$expected_message" >&2
    cat "$TEST_ROOT/$scenario.out" >&2
    exit 1
  }
  printf 'PASS: %s rejected\n' "$scenario"
}

new_repository baseline
expect_pass baseline

new_repository allowed-portable-values
cat >"$REPOSITORY/infrastructure/tests/allowed-values.txt" <<'EOF'
${ACCOUNT_ID}
arn:$AWS_PARTITION:sqs:$AWS_REGION:$ACCOUNT_ID:$SQS_QUEUE_NAME
arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
000000123456
EOF
mkdir -p "$REPOSITORY/infrastructure/build/generated-config"
printf '{"Version":"2012-10-17","Statement":[]}\n' \
  >"$REPOSITORY/infrastructure/build/generated-config/valid.json"
(cd "$REPOSITORY" && git add infrastructure/tests/allowed-values.txt)
expect_pass allowed-portable-values

new_repository account-id
bad_account="123456""789012"
printf '\nAccount: %s\n' "$bad_account" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure account-id "literal 12-digit AWS account ID"

new_repository account-arn
bad_account="123456""789012"
printf 'arn:aws:lambda:us-east-1:%s:function:portable\n' "$bad_account" \
  >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure account-arn "literal account-scoped AWS ARN"

new_repository sqs-url
bad_account="123456""789012"
printf 'https://sqs.us-east-1.amazonaws.com/%s/portable\n' "$bad_account" \
  >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure sqs-url "literal account-scoped SQS queue URL"

new_repository legacy-resource
legacy_bucket="cloud-project-file-""sharing-bucket"
printf '%s\n' "$legacy_bucket" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure legacy-resource "known legacy AWS identifier"

new_repository generated-role
generated_role="PortableHandler-role-""abc12345"
printf '%s\n' "$generated_role" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure generated-role "console-generated IAM name"

new_repository generated-logging-policy
generated_logging="AWSLambdaBasicExecutionRole-""abcdef12"
printf '%s\n' "$generated_logging" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure generated-logging-policy "console-generated IAM name"

new_repository access-key
access_key="AKIA""ABCDEFGHIJKLMNOP"
printf '%s\n' "$access_key" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure access-key "AWS access-key-shaped value"

new_repository private-key
private_header="-----BEGIN ""PRIVATE KEY-----"
printf '%s\n' "$private_header" >>"$REPOSITORY/README.md"
(cd "$REPOSITORY" && git add README.md)
expect_failure private-key "private-key header"

new_repository tracked-env
printf 'AWS_PROFILE=unsafe\n' >"$REPOSITORY/infrastructure/.env"
(cd "$REPOSITORY" && git add -f infrastructure/.env)
expect_failure tracked-env "tracked local environment file"

new_repository tracked-state
printf '{}\n' >"$REPOSITORY/infrastructure/state/deployment.json"
(cd "$REPOSITORY" && git add -f infrastructure/state/deployment.json)
expect_failure tracked-state "tracked deployment state"

new_repository tracked-zip
printf 'zip\n' >"$REPOSITORY/lambda.zip"
(cd "$REPOSITORY" && git add -f lambda.zip)
expect_failure tracked-zip "tracked ZIP archive"

new_repository tracked-node-modules
mkdir -p "$REPOSITORY/node_modules/example"
printf 'module\n' >"$REPOSITORY/node_modules/example/index.js"
(cd "$REPOSITORY" && git add -f node_modules/example/index.js)
expect_failure tracked-node-modules "tracked dependency"

new_repository invalid-template
printf '{invalid\n' \
  >"$REPOSITORY/infrastructure/config/templates/lambda-trust-policy.json"
(cd "$REPOSITORY" && git add infrastructure/config/templates/lambda-trust-policy.json)
expect_failure invalid-template "invalid JSON template"

new_repository unresolved-generated
mkdir -p "$REPOSITORY/infrastructure/build/generated-config"
printf '{"Resource":"${UNRESOLVED}"}\n' \
  >"$REPOSITORY/infrastructure/build/generated-config/bad.json"
expect_failure unresolved-generated "unresolved generated placeholder"

new_repository empty-document
: >"$REPOSITORY/infrastructure/docs/architecture.md"
(cd "$REPOSITORY" && git add infrastructure/docs/architecture.md)
expect_failure empty-document "required documentation missing or empty"

printf 'All portability audit regression tests passed.\n'
