#!/usr/bin/env bash
#
# push.sh — repo → n8n.
#
#   ./scripts/push.sh --instance <cloud|selfhosted> (--only <slug> | --all) [--dry-run]
#
# Scope is REQUIRED. --only <slug> pushes one workflow; --all pushes every file
# in workflows/. A bare invocation is a usage error and writes nothing: the
# default instance is cloud, which is production, and the scope used to default
# to everything — so the shortest command was also the widest one.
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
ALL=0
DRY_RUN=0

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE_ARG="${2:?--instance needs a value}"; shift 2 ;;
    --only)     ONLY="${2:?--only needs a value}";             shift 2 ;;
    --all)      ALL=1;                                         shift   ;;
    --dry-run)  DRY_RUN=1;                                     shift   ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

require_deps jq curl
load_env
resolve_instance "$INSTANCE_ARG"

# Scope check sits after resolve_instance so the instance guards keep reporting
# first — a bad or unconfigured --instance is still the error you get told about.
if [[ -n "$ONLY" && "$ALL" -eq 1 ]]; then
  usage >&2
  die "--only and --all are contradictory; pass one"
fi

# A bare push targeted every file in workflows/, against a default instance of
# cloud, which is production. Requiring the scope makes the blast radius
# something the caller typed rather than something they inherited.
if [[ -z "$ONLY" && "$ALL" -eq 0 ]]; then
  usage >&2
  die "no scope given: pass --only <slug> for one workflow, or --all for every file in workflows/"
fi

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

  # A stale index entry must not be fatal. The index is a cache, not the source
  # of truth — lib.sh already treats a corrupt one as cheaply rebuilt. An id
  # that is gone upstream is the same class of problem: the workflow was
  # deleted, the instance was rebuilt, or the index was copied between repos.
  #
  # Dying here broke the one case this script exists for. Restore-from-git runs
  # precisely when the workflows are missing upstream, and the index still names
  # their old ids — so the update branch was taken, the GET 404'd, and `set -e`
  # killed the push before the create branch could ever be reached.
  live=""
  if [[ -n "$id" ]]; then
    if ! live="$(api GET "/workflows/$id" 2>/dev/null)"; then
      # Only "gone" is recoverable. A 401 or a 500 means we never got a real
      # answer about what is on the instance, and creating on that basis would
      # duplicate workflows that are actually still there.
      status="$(api_status GET "/workflows/$id")"
      case "$status" in
        404) warn "$slug: index names id $id on '$INSTANCE', but it is gone upstream (404)"
             id=""; live="" ;;
        *)   die "$slug: cannot read id $id from '$INSTANCE' (HTTP $status). Not a missing workflow — refusing to create a duplicate." ;;
      esac
    fi
  fi

  # No usable id — either the index had none, or the one it had was dead. Match
  # by name before creating, so a workflow that came back under a new id gets
  # updated rather than duplicated.
  if [[ -z "$id" ]]; then
    existing="$(api GET "/workflows?limit=250" \
      | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)"
    if [[ -n "$existing" ]]; then
      id="$existing"
      info "matched '$name' to existing id $id on '$INSTANCE' by name"
      live="$(api GET "/workflows/$id")"
    fi
  fi

  if [[ -n "$id" ]]; then
    # --- UPDATE: merge live credentials back in before writing ---

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
      # Record the id actually used. When it came from the name-match fallback
      # it differs from whatever the index held, and leaving the old value there
      # means the next push repeats the same dead lookup.
      index_set "$slug" "$INSTANCE" "$id" "$name"
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
