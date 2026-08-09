#!/usr/bin/env bash
# Shared helpers for pull.sh / push.sh / validate.sh.
# Sourced, not executed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/workflows"
INDEX_FILE="$WORKFLOW_DIR/.index.json"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*" >&2; }
warn() { printf 'warn:  %s\n' "$*" >&2; }

require_deps() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
  done
}

# Load .env if present. Never committed; see .gitignore.
load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
  fi
}

# resolve_instance <cloud|selfhosted>
# Exports N8N_URL, N8N_API_KEY, INSTANCE.
resolve_instance() {
  local inst="${1:-cloud}"
  case "$inst" in
    cloud)
      N8N_URL="${N8N_CLOUD_URL:-}"
      N8N_API_KEY="${N8N_CLOUD_API_KEY:-}"
      ;;
    selfhosted)
      N8N_URL="${N8N_SELFHOSTED_URL:-}"
      N8N_API_KEY="${N8N_SELFHOSTED_API_KEY:-}"
      ;;
    *)
      die "unknown instance '$inst' (expected: cloud | selfhosted)"
      ;;
  esac

  [[ -n "$N8N_URL" ]] \
    || die "instance '$inst': URL not set. Copy .env.example to .env and fill it in."
  [[ -n "$N8N_API_KEY" ]] \
    || die "instance '$inst': API key not set. Copy .env.example to .env and fill it in."

  N8N_URL="${N8N_URL%/}"
  INSTANCE="$inst"
  export N8N_URL N8N_API_KEY INSTANCE
}

# api <METHOD> <path> [curl args...]
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body \
    -X "$method" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$N8N_URL/api/v1$path" "$@"
}

# slugify <string> -> filesystem-safe lowercase slug
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}

# Normalise a workflow into the committed shape:
#   - only the four fields the n8n API accepts on write
#   - credentials stripped from every node
#   - pinned test data dropped
#   - keys sorted, so diffs are real changes and not key reordering
normalise_workflow() {
  jq -S '{
    name: .name,
    nodes: [ (.nodes // [])[] | del(.credentials) ],
    connections: (.connections // {}),
    settings: (.settings // {})
  } | del(.pinData)'
}

index_get() { # index_get <slug> <instance> -> id or empty
  [[ -f "$INDEX_FILE" ]] || { printf ''; return 0; }
  jq -r --arg s "$1" --arg i "$2" '.[$s][$i] // ""' "$INDEX_FILE"
}

index_set() { # index_set <slug> <instance> <id> <workflow name>
  local slug="$1" inst="$2" id="$3" name="$4" tmp
  [[ -f "$INDEX_FILE" ]] || printf '{}\n' > "$INDEX_FILE"
  tmp="$(mktemp)"
  jq -S --arg s "$slug" --arg i "$inst" --arg id "$id" --arg n "$name" \
    '.[$s] = ((.[$s] // {}) | .[$i] = $id | .name = $n)' \
    "$INDEX_FILE" > "$tmp"
  mv "$tmp" "$INDEX_FILE"
}
