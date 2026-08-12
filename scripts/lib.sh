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

# api_status <METHOD> <path> -> prints the HTTP status code, always exits 0
#
# `api` fails the same way for 404, 401, and 500, which is not good enough when
# the caller wants to treat "gone" differently from "cannot talk to the API".
# Recovering from a missing workflow is correct; silently recovering from a bad
# key would create duplicates on an instance we never really read.
api_status() {
  local method="$1" path="$2"
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' \
    -X "$method" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$N8N_URL/api/v1$path" "$@" 2>/dev/null || true
}

# slugify <string> -> filesystem-safe lowercase slug
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}

# prefix_matches <slug> <prefix>
# True when <prefix> is a whole leading dash-delimited segment of <slug>.
#
# slugify() strips trailing separators, so "ap-" and "ap" both normalise to
# "ap". Globbing on "ap"* would therefore also match api-gateway and
# apple-sorter — broader than intended, in the direction of pulling other
# builds' workflows, which is what the prefix exists to prevent. Requiring the
# "-" boundary makes a prefix a segment rather than a substring.
#
# An empty prefix matches everything; callers decide whether that is allowed.
prefix_matches() {
  local slug="$1" base
  base="$(slugify "$2")"
  [[ -n "$base" ]] || return 0
  [[ "$slug" == "$base" || "$slug" == "$base-"* ]]
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

# Create the index if absent, and repair it if it is not valid JSON.
# A corrupt index must not take down a pull — it is a cache, not the source
# of truth, and it is cheaply rebuilt by pulling again.
ensure_index() {
  if [[ ! -f "$INDEX_FILE" ]] || ! jq empty "$INDEX_FILE" 2>/dev/null; then
    [[ ! -f "$INDEX_FILE" ]] || warn "index was not valid JSON — resetting $INDEX_FILE"
    printf '{}\n' > "$INDEX_FILE"
  fi
}

index_get() { # index_get <slug> <instance> -> id or empty
  ensure_index
  jq -r --arg s "$1" --arg i "$2" '.[$s][$i] // ""' "$INDEX_FILE"
}

index_set() { # index_set <slug> <instance> <id> <workflow name>
  local slug="$1" inst="$2" id="$3" name="$4" tmp
  ensure_index
  tmp="$(mktemp)"
  jq -S --arg s "$slug" --arg i "$inst" --arg id "$id" --arg n "$name" \
    '.[$s] = ((.[$s] // {}) | .[$i] = $id | .name = $n)' \
    "$INDEX_FILE" > "$tmp"
  mv "$tmp" "$INDEX_FILE"
}
