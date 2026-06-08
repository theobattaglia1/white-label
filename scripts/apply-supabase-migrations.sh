#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI is required: https://supabase.com/docs/guides/cli" >&2
  exit 1
fi

set -a
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
set +a

supabase db push --include-all
