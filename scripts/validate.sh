#!/usr/bin/env bash
#
# validate.sh — the guard. Runs identically locally and in CI, so a local pass
# means a CI pass.
#
#   ./scripts/validate.sh
#
# Checks every workflows/*.json for:
#   1. valid JSON
#   2. required shape (name, nodes array, connections object)
#   3. no credentials object          <- the leak that matters most
#   4. no secret-shaped strings
#   5. normalised formatting          <- guarantees diffs are real changes
#
# Needs no API key and no network. Exits non-zero on the first category that fails.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_deps jq

failures=0
fail() { printf 'FAIL   %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'ok     %s\n' "$*"; }

[[ -d "$WORKFLOW_DIR" ]] || { printf 'no workflows/ directory — nothing to validate\n'; exit 0; }

shopt -s nullglob
files=( "$WORKFLOW_DIR"/*.json )
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  printf 'no workflow files yet — nothing to validate\n'
  exit 0
fi

for f in "${files[@]}"; do
  rel="${f#"$REPO_ROOT"/}"

  # 1. valid JSON
  if ! jq empty "$f" 2>/dev/null; then
    fail "$rel — not valid JSON"
    continue
  fi

  # 2. required shape
  shape="$(jq -r '
    if (.name | type) != "string" or (.name | length) == 0 then "missing or empty .name"
    elif (.nodes | type) != "array" then "missing .nodes array"
    elif (.connections | type) != "object" then "missing .connections object"
    else "" end' "$f")"
  if [[ -n "$shape" ]]; then
    fail "$rel — $shape"
    continue
  fi

  # 3. credentials must never be committed
  cred_nodes="$(jq -r '[ .nodes[] | select(.credentials != null) | .name ] | join(", ")' "$f")"
  if [[ -n "$cred_nodes" ]]; then
    fail "$rel — credentials object present on node(s): $cred_nodes"
    continue
  fi

  # 4. secret-shaped strings anywhere in the file
  #    Targeted patterns only — broad ones produce false positives on real workflows.
  if grep -qE '(sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$f"; then
    fail "$rel — contains a secret-shaped string (see match above)"
    continue
  fi

  # 5. formatting is exactly what normalise_workflow produces
  if ! diff -q <(normalise_workflow < "$f") "$f" >/dev/null 2>&1; then
    fail "$rel — not normalised. Run ./scripts/pull.sh, or reformat with:
         jq -S '{name, nodes: [(.nodes//[])[] | del(.credentials)], connections: (.connections//{}), settings: (.settings//{})}' '$rel' > tmp && mv tmp '$rel'"
    continue
  fi

  pass "$rel"
done

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf '%d file(s) failed validation\n' "$failures" >&2
  exit 1
fi
printf 'all %d workflow file(s) valid\n' "${#files[@]}"
