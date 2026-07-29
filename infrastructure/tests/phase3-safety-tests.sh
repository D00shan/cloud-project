#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
PROJECT_ROOT="$(cd -- "$INFRASTRUCTURE_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}

trap cleanup EXIT

for command_name in bash jq npm zip unzip tar sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { printf 'Required test command missing: %s\n' "$command_name" >&2; exit 1; }
done

new_workspace() {
  local name="$1"
  local workspace="$TEST_ROOT/$name"

  mkdir -p "$workspace"

  (
    cd "$PROJECT_ROOT"
    tar \
      --exclude='infrastructure/.env' \
      --exclude='infrastructure/build' \
      --exclude='infrastructure/state/deployment.json' \
      -cf - \
      infrastructure \
      lambdas
  ) | (
    cd "$workspace"
    tar -xf -
  )

  mkdir -p \
    "$workspace/infrastructure/build" \
    "$workspace/infrastructure/state" \
    "$workspace/mock-bin"

  cp "$workspace/infrastructure/config/project.env.example" \
    "$workspace/infrastructure/.env"
  cp "$TEST_DIR/fixtures/aws" "$workspace/mock-bin/aws"
  cp "$TEST_DIR/fixtures/sleep" "$workspace/mock-bin/sleep"
  chmod +x "$workspace/mock-bin/aws" "$workspace/mock-bin/sleep"

  printf '%s\n' "$workspace"
}

initialize_mock_state() {
  local state_file="$1"

  jq -n '{
    bucket:{exists:false,tags:[],notification:false},
    queue:{
      exists:false,
      name:"cloud-file-compression-cli-test-queue",
      tags:{},
      attributes_applied:false
    },
    role:{
      exists:false,
      tags:[],
      logging_policy:false,
      s3_policy:false,
      sqs_policy:false
    },
    lambda:{
      exists:false,
      name:"cloud-file-compression-cli-test-handler",
      tags:{}
    },
    mapping:{exists:false,enabled:false}
  }' >"$state_file"
}

run_deploy() {
  local workspace="$1"
  shift

  (
    cd "$workspace"
    env \
      PATH="$workspace/mock-bin:$PATH" \
      MOCK_AWS_STATE_FILE="$workspace/mock-aws-state.json" \
      MOCK_AWS_LOG_FILE="$workspace/mock-aws.log" \
      "$@" \
      ./infrastructure/deploy.sh
  )
}

run_destroy() {
  local workspace="$1"
  shift

  (
    cd "$workspace"
    env \
      PATH="$workspace/mock-bin:$PATH" \
      MOCK_AWS_STATE_FILE="$workspace/mock-aws-state.json" \
      MOCK_AWS_LOG_FILE="$workspace/mock-aws.log" \
      "$@" \
      ./infrastructure/destroy.sh \
      --yes 'cloud-file-compression/cli-test'
  )
}

assert_failure() {
  local output_file="$1"
  shift

  if "$@" >"$output_file" 2>&1; then
    printf 'Expected command to fail: %s\n' "$*" >&2
    return 1
  fi
}

assert_fully_destroyed() {
  local workspace="$1"

  jq -e '
    (.bucket.exists | not) and
    (.queue.exists | not) and
    (.role.exists | not) and
    (.role.logging_policy | not) and
    (.role.s3_policy | not) and
    (.role.sqs_policy | not) and
    (.lambda.exists | not) and
    (.mapping.exists | not)
  ' "$workspace/mock-aws-state.json" >/dev/null

  [[ ! -f "$workspace/infrastructure/state/deployment.json" ]]
}

printf '1. Fresh deployment and unchanged rerun...\n'
workspace="$(new_workspace fresh)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
run_deploy "$workspace" >/dev/null
jq -e '
  .deployment_status == "complete" and
  (.deployment_configuration_fingerprint | length == 64) and
  (.lambda_package_sha256 | length == 64)
' "$workspace/infrastructure/state/deployment.json" >/dev/null
first_package_hash="$(
  jq -r '.lambda_package_sha256' \
    "$workspace/infrastructure/state/deployment.json"
)"
: >"$workspace/mock-aws.log"
rerun_output="$workspace/rerun.out"
run_deploy "$workspace" >"$rerun_output"
grep -Fq 'Rerun fingerprints match' "$rerun_output"
[[ "$first_package_hash" == "$(
  jq -r '.lambda_package_sha256' \
    "$workspace/infrastructure/state/deployment.json"
)" ]]
printf '   PASS\n'

printf '2. Managed-policy partial failure remains destroyable...\n'
workspace="$(new_workspace partial-managed)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/deploy-failure.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=after-managed-policy
jq -e '.role.exists and .role.logging_policy and (.role.s3_policy | not)' \
  "$workspace/mock-aws-state.json" >/dev/null
run_destroy "$workspace" >/dev/null
assert_fully_destroyed "$workspace"
printf '   PASS\n'

printf '3. One-inline-policy partial failure remains destroyable...\n'
workspace="$(new_workspace partial-inline)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/deploy-failure.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=after-s3-inline-policy
jq -e '.role.logging_policy and .role.s3_policy and (.role.sqs_policy | not)' \
  "$workspace/mock-aws-state.json" >/dev/null
run_destroy "$workspace" >/dev/null
assert_fully_destroyed "$workspace"
printf '   PASS\n'

printf '4. Missing IAM policies are accepted during teardown...\n'
workspace="$(new_workspace missing-policies)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/deploy-failure.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=before-managed-policy
jq -e '
  .role.exists and
  (.role.logging_policy | not) and
  (.role.s3_policy | not) and
  (.role.sqs_policy | not)
' "$workspace/mock-aws-state.json" >/dev/null
run_destroy "$workspace" >"$workspace/destroy.out"
grep -Fq 'already absent' "$workspace/destroy.out"
assert_fully_destroyed "$workspace"
printf '   PASS\n'

printf '5. AccessDenied during IAM cleanup is fatal...\n'
workspace="$(new_workspace cleanup-denied)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/deploy-failure.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=after-managed-policy
assert_failure "$workspace/destroy-failure.out" \
  run_destroy "$workspace" MOCK_IAM_CLEANUP_ACCESS_DENIED=1
grep -Fq 'AccessDenied' "$workspace/destroy-failure.out"
[[ -f "$workspace/infrastructure/state/deployment.json" ]]
jq -e '.role.exists and .role.logging_policy' \
  "$workspace/mock-aws-state.json" >/dev/null
printf '   PASS\n'

printf '6. Changed configuration and code are rejected before mutation...\n'
workspace="$(new_workspace fingerprint)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
run_deploy "$workspace" >/dev/null
sed -i 's/LAMBDA_MEMORY_SIZE=256/LAMBDA_MEMORY_SIZE=257/' \
  "$workspace/infrastructure/.env"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/config-drift.out" run_deploy "$workspace"
grep -Fq 'Deployment configuration changed' "$workspace/config-drift.out"
! grep -Eq \
  'create-bucket|put-bucket|create-queue|set-queue|create-role|attach-role|put-role|create-function|create-event|put-bucket-notification' \
  "$workspace/mock-aws.log"
sed -i 's/LAMBDA_MEMORY_SIZE=257/LAMBDA_MEMORY_SIZE=256/' \
  "$workspace/infrastructure/.env"
printf '\n// package fingerprint change\n' >> \
  "$workspace/lambdas/compression-handler/index.mjs"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/code-drift.out" run_deploy "$workspace"
grep -Fq 'Lambda package content changed' "$workspace/code-drift.out"
! grep -Eq \
  'create-bucket|put-bucket|create-queue|set-queue|create-role|attach-role|put-role|create-function|create-event|put-bucket-notification' \
  "$workspace/mock-aws.log"
printf '   PASS\n'

printf '7. Ownership mismatch blocks destruction before mutation...\n'
workspace="$(new_workspace ownership)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
run_deploy "$workspace" >/dev/null
temporary_state="$workspace/mock-aws-state.tmp"
jq '
  .role.tags |= map(
    if .Key == "Project" then .Value = "unowned-project" else . end
  )
' "$workspace/mock-aws-state.json" >"$temporary_state"
mv "$temporary_state" "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/ownership.out" run_destroy "$workspace"
grep -Fq 'ownership tags do not match' "$workspace/ownership.out"
! grep -Eq \
  'delete-|detach-role|put-bucket-notification|abort-multipart' \
  "$workspace/mock-aws.log"
jq -e '.role.exists and .bucket.exists and .queue.exists' \
  "$workspace/mock-aws-state.json" >/dev/null
printf '   PASS\n'

printf '8. Bash and JSON validation...\n'
while IFS= read -r script; do
  bash -n "$script"
done < <(
  find "$INFRASTRUCTURE_DIR" \
    -type f \
    \( -name '*.sh' -o -path '*/tests/fixtures/aws' -o -path '*/tests/fixtures/sleep' \) \
    -not -path '*/build/*' \
    | sort
)

for template in "$INFRASTRUCTURE_DIR"/config/templates/*; do
  [[ -f "$template" ]] || continue
  jq empty "$template"
done
printf '   PASS\n'

printf 'All Phase 3 safety tests passed.\n'
