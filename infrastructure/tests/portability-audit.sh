#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'Portability audit must run inside a Git repository.\n' >&2; exit 1; }
cd "$REPOSITORY_ROOT"

all_tracked_files=()
portable_text_files=()
excluded_snapshot_prefix="docs/current-aws-""state/"
excluded_exporter="tools/export-current-""state.sh"

while IFS= read -r -d '' tracked_file; do
  all_tracked_files+=("$tracked_file")

  if [[ "$tracked_file" == "$excluded_snapshot_prefix"* ||
        "$tracked_file" == "$excluded_exporter" ]]; then
    continue
  fi

  [[ -f "$tracked_file" ]] || continue
  if grep -Iq '' -- "$tracked_file"; then
    portable_text_files+=("$tracked_file")
  fi
done < <(git ls-files -z)

fail_path() {
  local rule="$1"
  local path="$2"
  printf 'Portability audit failed (%s): %s\n' "$rule" "$path" >&2
  exit 1
}

fail_match() {
  local rule="$1"
  local path="$2"
  local match="$3"
  printf 'Portability audit failed (%s): %s:%s\n' \
    "$rule" "$path" "$match" >&2
  exit 1
}

for tracked_file in "${all_tracked_files[@]}"; do
  case "$tracked_file" in
    .env|*/.env)
      fail_path "tracked local environment file" "$tracked_file"
      ;;
    infrastructure/state/.gitkeep|infrastructure/build/.gitkeep)
      ;;
    infrastructure/state/*)
      fail_path "tracked deployment state" "$tracked_file"
      ;;
    infrastructure/build/*)
      fail_path "tracked generated build output" "$tracked_file"
      ;;
    *.zip)
      fail_path "tracked ZIP archive" "$tracked_file"
      ;;
    node_modules/*|*/node_modules/*)
      fail_path "tracked dependency" "$tracked_file"
      ;;
    *.pem|*.key|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519)
      fail_path "tracked private-key path" "$tracked_file"
      ;;
    */phase4-validation/*|*/validation-artifacts/*|*.tmp|*.log)
      fail_path "tracked temporary validation artifact" "$tracked_file"
      ;;
  esac
done

synthetic_test_account="000000123456"
for portable_file in "${portable_text_files[@]}"; do
  while IFS=: read -r line_number literal_arn; do
    [[ -n "$literal_arn" ]] || continue
    arn_account="$(
      grep -oP '(?<=:)[0-9]{12}(?=:)' <<<"$literal_arn" | head -n1 || true
    )"
    if [[ "$portable_file" == infrastructure/tests/* &&
          "$arn_account" == "$synthetic_test_account" ]]; then
      continue
    fi
    fail_match "literal account-scoped AWS ARN" \
      "$portable_file" "$line_number:$literal_arn"
  done < <(
    grep -nPo \
      'arn:(aws|aws-us-gov|aws-cn):[^[:space:]"'\''`]*:[0-9]{12}:[^[:space:]"'\''`)]+' \
      -- "$portable_file" || true
  )

  while IFS=: read -r line_number queue_url; do
    [[ -n "$queue_url" ]] || continue
    fail_match "literal account-scoped SQS queue URL" \
      "$portable_file" "$line_number:$queue_url"
  done < <(
    grep -nPo \
      'https://sqs\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/[0-9]{12}/[^[:space:]"'\''`)]+' \
      -- "$portable_file" || true
  )

  while IFS=: read -r line_number account_id; do
    [[ -n "$account_id" ]] || continue
    if [[ "$portable_file" == infrastructure/tests/* &&
          "$account_id" == "$synthetic_test_account" ]]; then
      continue
    fi
    fail_match "literal 12-digit AWS account ID" \
      "$portable_file" "$line_number:$account_id"
  done < <(
    grep -nPo '(?<![0-9])[0-9]{12}(?![0-9])' -- "$portable_file" || true
  )
done

legacy_account_id="555751""475057"
legacy_bucket_name="cloud-project-file-""sharing-bucket"
legacy_queue_name="file-compression-""queue"
legacy_lambda_name="FileCompression""Handler"
legacy_role_name="FileCompression""Handler-role-""fntiwpdd"
legacy_logging_policy="AWSLambdaBasicExecutionRole-""3715b034-2183-4f4f-a3cd-70ec92ac7695"
retired_snapshot_path="$excluded_snapshot_prefix"
retired_exporter_path="$excluded_exporter"

for portable_file in "${portable_text_files[@]}"; do
  for denied_identifier in \
    "$legacy_account_id" "$legacy_bucket_name" "$legacy_queue_name" \
    "$legacy_lambda_name" "$legacy_role_name" "$legacy_logging_policy"; do
    match="$(grep -Fn -- "$denied_identifier" "$portable_file" | head -n1 || true)"
    [[ -z "$match" ]] \
      || fail_match "known legacy AWS identifier" "$portable_file" "$match"
  done

  for retired_reference in "$retired_snapshot_path" "$retired_exporter_path"; do
    match="$(grep -Fn -- "$retired_reference" "$portable_file" | head -n1 || true)"
    [[ -z "$match" ]] \
      || fail_match "reference to retired legacy material" "$portable_file" "$match"
  done

  if [[ "$portable_file" != infrastructure/tests/* ]]; then
    match="$(
      grep -nE \
        'AWSLambdaBasicExecutionRole-[A-Za-z0-9][A-Za-z0-9-]{5,}|[A-Za-z0-9_-]*(Handler|Function|Lambda)[A-Za-z0-9_-]*-role-[a-z0-9]{6,}' \
        -- "$portable_file" | head -n1 || true
    )"
    [[ -z "$match" ]] \
      || fail_match "console-generated IAM name" "$portable_file" "$match"
  fi

  match="$(
    grep -nE '(AKIA|ASIA)[A-Z0-9]{16}' -- "$portable_file" | head -n1 || true
  )"
  [[ -z "$match" ]] \
    || fail_match "AWS access-key-shaped value" "$portable_file" "$match"

  match="$(
    grep -nE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' \
      "$portable_file" | head -n1 || true
  )"
  [[ -z "$match" ]] \
    || fail_match "private-key header" "$portable_file" "$match"
done

for tracked_file in "${all_tracked_files[@]}"; do
  [[ "$tracked_file" == *.sh ]] || continue
  if [[ "$tracked_file" == "$excluded_exporter" ]]; then
    continue
  fi
  [[ -f "$tracked_file" ]] || fail_path "tracked shell script missing" "$tracked_file"
  if ! syntax_error="$(bash -n "$tracked_file" 2>&1)"; then
    fail_match "Bash syntax" "$tracked_file" "$syntax_error"
  fi
done

required_documents=(
  infrastructure/docs/README.md
  infrastructure/docs/architecture.md
  infrastructure/docs/configuration-reference.md
  infrastructure/docs/deployment-guide.md
  infrastructure/docs/destruction-guide.md
  infrastructure/docs/portability-rehearsal.md
  infrastructure/docs/troubleshooting.md
  infrastructure/docs/validation-guide.md
)
for required_document in "${required_documents[@]}"; do
  [[ -s "$required_document" ]] \
    || fail_path "required documentation missing or empty" "$required_document"
done

for tracked_file in "${all_tracked_files[@]}"; do
  case "$tracked_file" in
    infrastructure/config/templates/*)
      [[ -f "$tracked_file" ]] || continue
      jq empty "$tracked_file" >/dev/null 2>&1 \
        || fail_path "invalid JSON template" "$tracked_file"
      ;;
  esac
done

generated_directory="infrastructure/build/generated-config"
if [[ -d "$generated_directory" ]]; then
  while IFS= read -r -d '' generated_file; do
    jq empty "$generated_file" >/dev/null 2>&1 \
      || fail_path "invalid generated JSON" "$generated_file"
    match="$(
      grep -nE '\$\{[^}]+\}' -- "$generated_file" | head -n1 || true
    )"
    [[ -z "$match" ]] \
      || fail_match "unresolved generated placeholder" "$generated_file" "$match"
  done < <(
    find "$generated_directory" -maxdepth 1 -type f -name '*.json' -print0
  )
fi

git diff --check >/dev/null \
  || { git diff --check >&2; exit 1; }

printf 'Portable repository static audit passed.\n'
