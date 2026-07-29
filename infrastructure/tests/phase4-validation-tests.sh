#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
WORKSPACE="$TEST_ROOT/workspace"

cleanup() {
  if [[ "${KEEP_PHASE4_TEST_ROOT:-0}" == 1 ]]; then
    printf 'Preserved Phase 4 test workspace: %s\n' "$TEST_ROOT" >&2
    return
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

for command_name in bash jq npm zip unzip tar gzip gunzip cmp; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { printf 'Required test command missing: %s\n' "$command_name" >&2; exit 1; }
done

mkdir -p "$WORKSPACE"
(
  cd "$PROJECT_ROOT"
  tar \
    --exclude='infrastructure/.env' \
    --exclude='infrastructure/build' \
    --exclude='infrastructure/state/deployment.json' \
    --exclude='lambdas/compression-handler/node_modules' \
    -cf - infrastructure lambdas
) | (cd "$WORKSPACE" && tar -xf -)
mkdir -p "$WORKSPACE/infrastructure/build" "$WORKSPACE/infrastructure/state" \
  "$WORKSPACE/mock-bin"
cp "$WORKSPACE/infrastructure/config/project.env.example" \
  "$WORKSPACE/infrastructure/.env"
cp "$TEST_DIR/fixtures/aws" "$WORKSPACE/mock-bin/aws"
cp "$TEST_DIR/fixtures/sleep" "$WORKSPACE/mock-bin/sleep"
chmod +x "$WORKSPACE/mock-bin/aws" "$WORKSPACE/mock-bin/sleep"

MOCK_STATE="$WORKSPACE/mock-aws-state.json"
MOCK_LOG="$WORKSPACE/mock-aws.log"
jq -n '{
  bucket:{exists:false,tags:[],notification:{},location:"",object_ownership:""},
  queue:{exists:false,name:"cloud-file-compression-cli-test-queue",tags:{},
    policy:"",visibility_timeout:"180",attributes_applied:false},
  role:{exists:false,name:"cloud-file-compression-cli-test-role",tags:[],
    logging_policy:false,s3_policy:false,sqs_policy:false},
  lambda:{exists:false,name:"cloud-file-compression-cli-test-handler",
    tags:{},function:{}},
  mapping:{exists:false,state:"Deleted",state_queries_remaining:0,configuration:{}},
  validation:{objects:{},uploaded_keys:[],deleted_keys:[]}
}' >"$MOCK_STATE"
: >"$MOCK_LOG"

run_aws_mock() {
  (
    cd "$WORKSPACE"
    env PATH="$WORKSPACE/mock-bin:$PATH" \
      MOCK_AWS_STATE_FILE="$MOCK_STATE" MOCK_AWS_LOG_FILE="$MOCK_LOG" \
      "$@"
  )
}

run_aws_mock ./infrastructure/deploy.sh >/dev/null
cp "$WORKSPACE/infrastructure/state/deployment.json" "$TEST_ROOT/deployment.seed.json"
cp "$MOCK_STATE" "$TEST_ROOT/aws.seed.json"

reset_seed() {
  cp "$TEST_ROOT/deployment.seed.json" \
    "$WORKSPACE/infrastructure/state/deployment.json"
  cp "$TEST_ROOT/aws.seed.json" "$MOCK_STATE"
  : >"$MOCK_LOG"
}

run_validate() {
  local environment_arguments=()
  while (( $# > 0 )) && [[ "$1" == *=* && "$1" != --* ]]; do
    environment_arguments+=("$1")
    shift
  done
  (
    cd "$WORKSPACE"
    env PATH="$WORKSPACE/mock-bin:$PATH" \
      MOCK_AWS_STATE_FILE="$MOCK_STATE" MOCK_AWS_LOG_FILE="$MOCK_LOG" \
      "${environment_arguments[@]}" \
      ./infrastructure/validate.sh "$@"
  )
}

assert_failure() {
  local output_file="$1"
  shift
  if "$@" >"$output_file" 2>&1; then
    printf 'Expected failure: %s\n' "$*" >&2
    return 1
  fi
}

printf '1. Refuses missing config, state, malformed state, and mismatched identity...\n'
reset_seed
assert_failure "$TEST_ROOT/missing-config.out" \
  run_validate --config "$WORKSPACE/infrastructure/missing.env"
grep -Fq 'Config file not found' "$TEST_ROOT/missing-config.out"

reset_seed
mv "$WORKSPACE/infrastructure/state/deployment.json" \
  "$WORKSPACE/infrastructure/state/deployment.saved"
assert_failure "$TEST_ROOT/missing-state.out" run_validate
grep -Fq 'Deployment state is missing' "$TEST_ROOT/missing-state.out"
mv "$WORKSPACE/infrastructure/state/deployment.saved" \
  "$WORKSPACE/infrastructure/state/deployment.json"

printf '{bad json\n' >"$WORKSPACE/infrastructure/state/deployment.json"
assert_failure "$TEST_ROOT/malformed-state.out" run_validate
grep -Fq 'not valid JSON' "$TEST_ROOT/malformed-state.out"

reset_seed
different_account="$(printf '%012d' 654321)"
assert_failure "$TEST_ROOT/account.out" \
  run_validate MOCK_AWS_ACCOUNT_ID="$different_account"
grep -Fq 'Deployment state does not match' "$TEST_ROOT/account.out"

reset_seed
cp "$WORKSPACE/infrastructure/.env" "$TEST_ROOT/region.env"
sed -i 's/AWS_REGION=us-east-1/AWS_REGION=eu-west-1/' "$TEST_ROOT/region.env"
assert_failure "$TEST_ROOT/region.out" \
  run_validate --config "$TEST_ROOT/region.env"
grep -Fq 'Deployment state does not match' "$TEST_ROOT/region.out"

reset_seed
cp "$WORKSPACE/infrastructure/.env" "$TEST_ROOT/project.env"
sed -i 's/ENVIRONMENT=cli-test/ENVIRONMENT=other-test/' "$TEST_ROOT/project.env"
assert_failure "$TEST_ROOT/project.out" \
  run_validate --config "$TEST_ROOT/project.env"
grep -Fq 'Deployment state does not match' "$TEST_ROOT/project.out"
printf '   PASS\n'

printf '2. Refuses incomplete and insecure deployments...\n'
reset_seed
jq '.deployment_status = "deploying"' \
  "$WORKSPACE/infrastructure/state/deployment.json" >"$TEST_ROOT/state.tmp"
mv "$TEST_ROOT/state.tmp" "$WORKSPACE/infrastructure/state/deployment.json"
assert_failure "$TEST_ROOT/incomplete.out" run_validate
grep -Fq 'Deployment state is incomplete' "$TEST_ROOT/incomplete.out"

for scenario in unexpected-iam-policy public-access wrong-notification wrong-mapping; do
  reset_seed
  assert_failure "$TEST_ROOT/$scenario.out" \
    run_validate PHASE4_SCENARIO="$scenario"
done
grep -Fq 'unexpected attached' "$TEST_ROOT/unexpected-iam-policy.out"
grep -Fq 'public-access block' "$TEST_ROOT/public-access.out"
grep -Fq 'notification does not exactly match' "$TEST_ROOT/wrong-notification.out"
grep -Fq 'Event-source mapping' "$TEST_ROOT/wrong-mapping.out"
printf '   PASS\n'

printf '3. End-to-end smoke test and scoped cleanup succeed...\n'
reset_seed
jq '.validation.objects["compressed/unrelated.gz"] = {
  kind:"destination",present:true,polls:2,file:"/not-used"
}' "$MOCK_STATE" >"$TEST_ROOT/mock.tmp"
mv "$TEST_ROOT/mock.tmp" "$MOCK_STATE"
run_validate >"$TEST_ROOT/success.out"
grep -Fq 'Test cases passed: 3/3' "$TEST_ROOT/success.out"
jq -e '
  (.validation.uploaded_keys | length) == 3 and
  (.validation.deleted_keys | length) == 3 and
  .validation.objects["compressed/unrelated.gz"].present == true and
  all(.validation.deleted_keys[];
    startswith("compressed/phase4-validation/"))
' "$MOCK_STATE" >/dev/null
printf '   PASS\n'

printf '4. Smoke-test failures remain fatal...\n'
for scenario in source-not-deleted compressed-timeout invalid-gzip \
  content-mismatch queue-nonempty logs-error logs-access-denied \
  unexpected-aws-error; do
  reset_seed
  assert_failure "$TEST_ROOT/$scenario.out" \
    run_validate PHASE4_SCENARIO="$scenario"
done
grep -Fq 'did not delete source object' "$TEST_ROOT/source-not-deleted.out"
grep -Fq 'Timed out waiting for compressed output' "$TEST_ROOT/compressed-timeout.out"
grep -Fq 'not valid gzip' "$TEST_ROOT/invalid-gzip.out"
grep -Fq 'Decompressed content differs' "$TEST_ROOT/content-mismatch.out"
grep -Fq 'did not remain empty' "$TEST_ROOT/queue-nonempty.out"
grep -Fq 'processing or runtime failure' "$TEST_ROOT/logs-error.out"
grep -Fq 'logs:FilterLogEvents permission' \
  "$TEST_ROOT/logs-access-denied.out"
grep -Fq 'failed ambiguously' "$TEST_ROOT/unexpected-aws-error.out"
printf '   PASS\n'

printf '5. --keep-artifacts retains only run outputs...\n'
reset_seed
run_validate --keep-artifacts >"$TEST_ROOT/keep.out"
grep -Fq 'Retained: s3://' "$TEST_ROOT/keep.out"
jq -e '
  (.validation.deleted_keys | length) == 0 and
  ([.validation.objects[] | select(.kind == "destination" and .present)] | length) == 3
' "$MOCK_STATE" >/dev/null
printf '   PASS\n'

printf '6. Shell syntax and portability audit...\n'
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$WORKSPACE/infrastructure" -type f -name '*.sh' | sort)
"$TEST_DIR/portability-audit.sh"
printf '   PASS\n'

printf 'All Phase 4 validation tests passed.\n'
