#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

portable_files=(README.md test.sh .gitignore)
while IFS= read -r file; do
  portable_files+=("$file")
done < <(
  find infrastructure lambdas -type f \
    -not -path 'infrastructure/build/*' \
    -not -path 'infrastructure/state/deployment.json' \
    -not -path 'infrastructure/.env' \
    -not -path '*/node_modules/*' \
    | sort
)

mapfile -t historical_accounts < <(
  git grep -hE '[0-9]{12}' -- docs/current-aws-state 2>/dev/null \
    | grep -oE '[0-9]{12}' | sort -u || true
)
mapfile -t historical_arns < <(
  git grep -hoE 'arn:[a-z0-9-]+:[^[:space:]\"`)]+' \
    -- docs/current-aws-state 2>/dev/null \
    | grep -v ':iam::aws:policy/' | sort -u || true
)
mapfile -t historical_queue_urls < <(
  git grep -hoE 'https://sqs\\.[^[:space:]\"`)]+' \
    -- docs/current-aws-state 2>/dev/null | sort -u || true
)
mapfile -t generated_role_names < <(
  git grep -hoE 'AWSLambda[A-Za-z0-9_-]+-[A-Za-z0-9]{6,}' \
    -- docs/current-aws-state 2>/dev/null | sort -u || true
)

for identifier in \
  "${historical_accounts[@]}" "${historical_arns[@]}" \
  "${historical_queue_urls[@]}" "${generated_role_names[@]}"; do
  [[ -n "$identifier" ]] || continue
  if grep -F -n -- "$identifier" "${portable_files[@]}" >/dev/null 2>&1; then
    printf 'Historical identifier leaked into portable tracked files: %s\n' \
      "$identifier" >&2
    exit 1
  fi
done

if git ls-files | grep -Eq \
  '(^|/)\\.env$|infrastructure/state/deployment\\.json$|infrastructure/build/.+\\.json$|\\.zip$|(^|/)node_modules/'; then
  printf 'Generated, state, dependency, archive, or local config is tracked.\n' >&2
  exit 1
fi

while IFS= read -r script; do
  bash -n "$script"
done < <(find infrastructure -type f -name '*.sh' -not -path '*/build/*' | sort)
bash -n test.sh

for json_file in infrastructure/config/templates/*; do
  [[ -f "$json_file" ]] && jq empty "$json_file"
done

if [[ -d infrastructure/build/generated-config ]]; then
  while IFS= read -r generated_file; do
    jq empty "$generated_file"
    ! grep -Eq '\\$\\{[^}]+\\}' "$generated_file" \
      || { printf 'Unresolved placeholder: %s\n' "$generated_file" >&2; exit 1; }
  done < <(
    find infrastructure/build/generated-config -type f -name '*.json' | sort
  )
fi

for required_doc in infrastructure/docs/*.md; do
  [[ -s "$required_doc" ]] \
    || { printf 'Required documentation is empty: %s\n' "$required_doc" >&2; exit 1; }
done

printf 'Portable repository static audit passed.\n'
