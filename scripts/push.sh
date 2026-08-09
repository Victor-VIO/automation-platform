#!/usr/bin/env bash
#
# push.sh — repo → n8n.
#
#   ./scripts/push.sh [--instance cloud|selfhosted] [--only <slug>] [--dry-run]
#
# NOT an editing path. Use n8n_update_partial_workflow (MCP) for daily authoring.
# This exists for restore-from-git, bulk deploy, and cross-instance promotion.
#
# Committed workflows have no credentials. Pushing them naively would wipe the
# live credential bindings on every update. So for each workflow this GETs the
# live version first, builds a `node name -> credentials` map from it, and
# reattaches those bindings before writing.
#
# Keyed on node NAME: renaming a node in the repo drops its binding. Those nodes
# are reported by name at the end rather than failing silently.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

INSTANCE_ARG="cloud"
ONLY=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE_ARG="${2:?--instance needs a value}"; shift 2 ;;
    --only)     ONLY="${2:?--only needs a value}";             shift 2 ;;
    --dry-run)  DRY_RUN=1;                                     shift   ;;
    -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

require_deps jq curl
load_env
resolve_instance "$INSTANCE_ARG"

[[ -d "$WORKFLOW_DIR" ]] || die "no workflows/ directory — run pull.sh first"

if [[ "$INSTANCE" == "cloud" && "$DRY_RUN" -eq 0 ]]; then
  warn "target is 'cloud', which is PRODUCTION. Ctrl-C within 5s to abort."
  sleep 5
fi

# Do NOT use ${DRY_RUN:+...} here: "0" is a non-empty string, so that form
# expands whenever the variable is set and would label every real push a
# dry run. Test the value, not whether it is set.
if [[ "$DRY_RUN" -eq 1 ]]; then
  DRY_LABEL=" [dry run]"
  DRY_SUFFIX=" (dry run — nothing written)"
else
  DRY_LABEL=""
  DRY_SUFFIX=""
fi

info "pushing to '$INSTANCE' ($N8N_URL)${DRY_LABEL}"

created=0
updated=0
unbound_report=""

shopt -s nullglob
for f in "$WORKFLOW_DIR"/*.json; do
  slug="$(basename "$f" .json)"

  if [[ -n "$ONLY" && "$slug" != "$(slugify "$ONLY")" ]]; then
    continue
  fi

  jq empty "$f" 2>/dev/null || die "$f is not valid JSON"

  local_json="$(jq -S '{name, nodes, connections, settings: (.settings // {})}' "$f")"
  name="$(jq -r '.name' <<<"$local_json")"
  id="$(index_get "$slug" "$INSTANCE")"

  if [[ -z "$id" ]]; then
    # Not on this instance yet. Try to match an existing workflow by name
    # before creating a duplicate.
    existing="$(api GET "/workflows?limit=250" \
      | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)"
    if [[ -n "$existing" ]]; then
      id="$existing"
      info "matched '$name' to existing id $id on '$INSTANCE' by name"
    fi
  fi

  if [[ -n "$id" ]]; then
    # --- UPDATE: merge live credentials back in before writing ---
    live="$(api GET "/workflows/$id")"

    payload="$(jq -n \
      --argjson local "$local_json" \
      --argjson live "$live" '
        (($live.nodes // [])
          | map(select(.credentials != null) | {key: .name, value: .credentials})
          | from_entries) as $c
        | $local
        | .nodes = [ .nodes[] | if $c[.name] then .credentials = $c[.name] else . end ]
      ')"

    # Nodes that carried credentials live but found no name match locally.
    lost="$(jq -r -n --argjson live "$live" --argjson merged "$payload" '
      (($live.nodes // []) | map(select(.credentials != null) | .name)) as $had
      | (($merged.nodes // []) | map(select(.credentials != null) | .name)) as $kept
      | ($had - $kept) | join(", ")
    ')"
    [[ -z "$lost" ]] || unbound_report+=$'\n'"    $slug: $lost"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "would update  $slug  (id $id)"
    else
      api PUT "/workflows/$id" -d "$payload" >/dev/null
      info "updated  $slug  (id $id)"
    fi
    updated=$((updated + 1))
  else
    # --- CREATE: nothing live to merge from; nodes arrive unbound ---
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "would create  $slug"
    else
      resp="$(api POST "/workflows" -d "$local_json")"
      new_id="$(jq -r '.id' <<<"$resp")"
      [[ -n "$new_id" && "$new_id" != "null" ]] || die "create failed for $slug: $resp"
      index_set "$slug" "$INSTANCE" "$new_id" "$name"
      info "created  $slug  (id $new_id) — credentials must be bound in the UI"
    fi
    created=$((created + 1))
  fi
done
shopt -u nullglob

info ""
info "'$INSTANCE': $updated updated, $created created${DRY_SUFFIX}"

if [[ -n "$unbound_report" ]]; then
  warn "these nodes had credentials live but no matching node name in the repo;"
  warn "they are now UNBOUND and must be rebound in the n8n UI:$unbound_report"
fi

[[ "$created" -eq 0 ]] || info "newly created workflows start inactive and unbound by design."
