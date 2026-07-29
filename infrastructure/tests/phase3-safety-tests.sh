#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
PROJECT_ROOT="$(cd -- "$INFRASTRUCTURE_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  if [[ "${KEEP_PHASE3_TEST_ROOT:-0}" == 1 ]]; then
    printf 'Preserved test workspace: %s\n' "$TEST_ROOT" >&2
    return
  fi
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
    bucket:{exists:false,tags:[],notification:{}},
    queue:{
      exists:false,
      name:"cloud-file-compression-cli-test-queue",
      tags:{},
      policy:"",
      visibility_timeout:"180",
      attributes_applied:false
    },
    role:{
      exists:false,
      name:"cloud-file-compression-cli-test-role",
      tags:[],
      logging_policy:false,
      s3_policy:false,
      sqs_policy:false
    },
    lambda:{
      exists:false,
      name:"cloud-file-compression-cli-test-handler",
      tags:{},
      function:{}
    },
    mapping:{exists:false,enabled:false,configuration:{}}
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

printf '8. Interrupted creations are adopted only after exact verification...\n'
for recovery_case in \
  bucket:create-bucket \
  queue:create-queue \
  role:create-role \
  lambda:create-function \
  mapping:create-event-source-mapping \
  notification:put-bucket-notification-configuration; do
  fail_point="${recovery_case%%:*}"
  creation_operation="${recovery_case#*:}"
  workspace="$(new_workspace "adopt-$fail_point")"
  initialize_mock_state "$workspace/mock-aws-state.json"
  : >"$workspace/mock-aws.log"
  assert_failure "$workspace/interrupted.out" \
    run_deploy "$workspace" MOCK_FAIL_POINT="$fail_point"
  creation_count_before="$(
    grep -c "$creation_operation" "$workspace/mock-aws.log" || true
  )"
  run_deploy "$workspace" >"$workspace/recovery.out"
  creation_count_after="$(
    grep -c "$creation_operation" "$workspace/mock-aws.log" || true
  )"
  [[ "$creation_count_after" == "$creation_count_before" ]]
  jq -e '.deployment_status == "complete"' \
    "$workspace/infrastructure/state/deployment.json" >/dev/null
done

for policy_fail_point in queue-policy after-managed-policy after-s3-inline-policy; do
  workspace="$(new_workspace "adopt-$policy_fail_point")"
  initialize_mock_state "$workspace/mock-aws-state.json"
  : >"$workspace/mock-aws.log"
  assert_failure "$workspace/interrupted.out" \
    run_deploy "$workspace" MOCK_FAIL_POINT="$policy_fail_point"
  run_deploy "$workspace" >"$workspace/recovery.out"
  jq -e '
    .deployment_status == "complete" and
    .steps.queue_policy_applied and
    .steps.role_policies_applied
  ' "$workspace/infrastructure/state/deployment.json" >/dev/null
done
printf '   PASS\n'

printf '9. Adoption rejects ownership and important-configuration drift...\n'
workspace="$(new_workspace adopt-foreign-bucket)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=bucket
jq '(.bucket.tags[] | select(.Key == "Project")).Value = "foreign"' \
  "$workspace/mock-aws-state.json" >"$workspace/mock-aws-state.tmp"
mv "$workspace/mock-aws-state.tmp" "$workspace/mock-aws-state.json"
assert_failure "$workspace/rejected.out" run_deploy "$workspace"
grep -Fq 'ownership tags do not match' "$workspace/rejected.out"

workspace="$(new_workspace adopt-queue-drift)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=queue
jq '.queue.visibility_timeout = "999"' \
  "$workspace/mock-aws-state.json" >"$workspace/mock-aws-state.tmp"
mv "$workspace/mock-aws-state.tmp" "$workspace/mock-aws-state.json"
assert_failure "$workspace/rejected.out" run_deploy "$workspace"
grep -Fq 'visibility timeout' "$workspace/rejected.out"

workspace="$(new_workspace adopt-lambda-drift)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=lambda
jq '.lambda.function.Configuration.Handler = "foreign.handler"' \
  "$workspace/mock-aws-state.json" >"$workspace/mock-aws-state.tmp"
mv "$workspace/mock-aws-state.tmp" "$workspace/mock-aws-state.json"
assert_failure "$workspace/rejected.out" run_deploy "$workspace"
grep -Fq 'code or configuration differs' "$workspace/rejected.out"

workspace="$(new_workspace adopt-mapping-drift)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=mapping
jq '.mapping.configuration.BatchSize = 2' \
  "$workspace/mock-aws-state.json" >"$workspace/mock-aws-state.tmp"
mv "$workspace/mock-aws-state.tmp" "$workspace/mock-aws-state.json"
assert_failure "$workspace/rejected.out" run_deploy "$workspace"
grep -Fq 'configuration differs' "$workspace/rejected.out"

workspace="$(new_workspace adopt-account-drift)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=bucket
different_account_id="$(printf '%012d' 654321)"
assert_failure "$workspace/rejected.out" \
  run_deploy "$workspace" MOCK_AWS_ACCOUNT_ID="$different_account_id"
grep -Fq 'Deployment state does not match the authenticated account' \
  "$workspace/rejected.out"

workspace="$(new_workspace adopt-region-drift)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
assert_failure "$workspace/interrupted.out" \
  run_deploy "$workspace" MOCK_FAIL_POINT=queue
queue_account_id="$(printf '%012d' 123456)"
cross_region_queue_arn="arn:aws:sqs:eu-west-1:$queue_account_id:cloud-file-compression-cli-test-queue"
assert_failure "$workspace/rejected.out" \
  run_deploy "$workspace" MOCK_QUEUE_ARN="$cross_region_queue_arn"
grep -Fq 'queue ARN does not match' "$workspace/rejected.out"
printf '   PASS\n'

printf '10. Destruction checkpoints exact already-absent resources...\n'
for absent_resource in mapping lambda role queue bucket; do
  workspace="$(new_workspace "destroy-absent-$absent_resource")"
  initialize_mock_state "$workspace/mock-aws-state.json"
  : >"$workspace/mock-aws.log"
  run_deploy "$workspace" >/dev/null
  jq \
    --arg resource "$absent_resource" \
    '
      .[$resource].exists = false |
      if $resource == "role" then
        .role.logging_policy = false |
        .role.s3_policy = false |
        .role.sqs_policy = false
      else . end
    ' \
    "$workspace/mock-aws-state.json" >"$workspace/mock-aws-state.tmp"
  mv "$workspace/mock-aws-state.tmp" "$workspace/mock-aws-state.json"
  run_destroy "$workspace" >"$workspace/destroy.out"
  grep -Fq 'already absent; checkpointing state' "$workspace/destroy.out"
  assert_fully_destroyed "$workspace"
done
printf '   PASS\n'

printf '11. Ambiguous lookup failures remain fatal and preserve state...\n'
for lookup_resource in bucket queue role lambda mapping; do
  workspace="$(new_workspace "lookup-error-$lookup_resource")"
  initialize_mock_state "$workspace/mock-aws-state.json"
  : >"$workspace/mock-aws.log"
  run_deploy "$workspace" >/dev/null
  : >"$workspace/mock-aws.log"
  assert_failure "$workspace/destroy.out" \
    run_destroy "$workspace" MOCK_LOOKUP_ERROR="$lookup_resource"
  grep -Fq 'refusing to infer absence' "$workspace/destroy.out"
  [[ -f "$workspace/infrastructure/state/deployment.json" ]]
  ! grep -Eq 'delete-|detach-role|put-bucket-notification' \
    "$workspace/mock-aws.log"
done
printf '   PASS\n'

printf '12. A second destroy cannot infer targets after state removal...\n'
workspace="$(new_workspace second-destroy)"
initialize_mock_state "$workspace/mock-aws-state.json"
: >"$workspace/mock-aws.log"
run_deploy "$workspace" >/dev/null
run_destroy "$workspace" >/dev/null
: >"$workspace/mock-aws.log"
assert_failure "$workspace/second-destroy.out" run_destroy "$workspace"
grep -Fq 'Deployment state is missing' "$workspace/second-destroy.out"
[[ ! -s "$workspace/mock-aws.log" ]]
printf '   PASS\n'

printf '13. Bash and JSON validation...\n'
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
