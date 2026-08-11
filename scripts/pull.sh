#!/usr/bin/env bash
#
# pull.sh — n8n → repo.
#
#   ./scripts/pull.sh [--instance cloud|selfhosted] [--only <name-or-slug>]
#
# Writes each workflow to workflows/<slug>.json with credentials stripped and
# keys sorted. Running it twice with no upstream change produces no git diff.
#
# Credentials never reach the repo. push.sh restores them from the target
# instance's own live state.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

INSTANCE_ARG="cloud"
ONLY=""
# One n8n instance serves every build. Without a prefix filter each build repo
# pulls every other build's workflows. Falls back to PULL_PREFIX from .env
# AFTER load_env runs - reading it here would be too early to see it.
#
# PREFIX_SET, not the emptiness of PREFIX, is what records that the user said
# something. "--all" means "no prefix", which is an empty PREFIX and therefore
# indistinguishable from "never set" if you test emptiness — that is what made
# --all a dead flag. Track intent separately.
PREFIX=""
PREFIX_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE_ARG="${2:?--instance needs a value}"; shift 2 ;;
    --only)     ONLY="${2:?--only needs a value}";             shift 2 ;;
    --prefix)   PREFIX="${2:?--prefix needs a value}"; PREFIX_SET=1; shift 2 ;;
    --all)      PREFIX=""; PREFIX_SET=1;                       shift   ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

require_deps jq curl
load_env
# An explicit --prefix or --all on the command line wins. Only fall back to
# .env when the user said nothing at all.
[[ "$PREFIX_SET" -eq 1 ]] || PREFIX="${PULL_PREFIX:-}"
resolve_instance "$INSTANCE_ARG"
mkdir -p "$WORKFLOW_DIR"
[[ -f "$INDEX_FILE" ]] || printf '{}\n' > "$INDEX_FILE"

info "pulling from '$INSTANCE' ($N8N_URL)"

cursor=""
pulled=0
skipped=0
skipped_slugs=""

while :; do
  if [[ -n "$cursor" ]]; then
    page="$(api GET "/workflows?limit=100&cursor=$cursor")"
  else
    page="$(api GET "/workflows?limit=100")"
  fi

  count="$(jq '.data | length' <<<"$page")"
  [[ "$count" -gt 0 ]] || break

  for i in $(seq 0 $((count - 1))); do
    wf="$(jq -c ".data[$i]" <<<"$page")"
    name="$(jq -r '.name' <<<"$wf")"
    id="$(jq -r '.id' <<<"$wf")"
    slug="$(slugify "$name")"

    if [[ -n "$PREFIX" ]] && ! prefix_matches "$slug" "$PREFIX"; then
      skipped=$((skipped + 1))
      skipped_slugs+=$'\n'"    $slug  (id $id)"
      continue
    fi

    if [[ -n "$ONLY" && "$slug" != "$(slugify "$ONLY")" && "$name" != "$ONLY" ]]; then
      skipped=$((skipped + 1))
      skipped_slugs+=$'\n'"    $slug  (id $id)"
      continue
    fi

    [[ -n "$slug" ]] || die "workflow '$name' (id $id) slugifies to an empty string; rename it"

    target="$WORKFLOW_DIR/$slug.json"

    # The list endpoint already returns nodes and connections, but fetch the
    # single workflow so this keeps working if that ever changes.
    full="$(api GET "/workflows/$id")"
    normalise_workflow <<<"$full" > "$target"

    index_set "$slug" "$INSTANCE" "$id" "$name"

    creds="$(jq '[ (.nodes // [])[] | select(.credentials != null) ] | length' <<<"$full")"
    info "pulled  $slug  (id $id, ${creds} node(s) with credentials — stripped)"
    pulled=$((pulled + 1))
  done

  cursor="$(jq -r '.nextCursor // ""' <<<"$page")"
  [[ -n "$cursor" ]] || break
done

info ""
info "pulled $pulled workflow(s) from '$INSTANCE'${ONLY:+ (filtered by --only $ONLY)}"
[[ "$skipped" -eq 0 ]] || info "skipped $skipped not matching${PREFIX:+ --prefix $PREFIX}${ONLY:+ --only $ONLY}"

# A pull that matched nothing is an error, not a quiet success. See the commit
# message for the argument; the short version is that this repo exists to stop
# workflows living only as mutable state in a hosted UI, and a sync tool that
# reports success while doing nothing is the exact failure it was built against.
if [[ "$pulled" -eq 0 ]]; then
  # Test the value, not whether the variable is set: "0" is a non-empty string,
  # so ${PREFIX_SET:+...} would expand in both cases. Same trap push.sh hit.
  if [[ "$PREFIX_SET" -eq 1 ]]; then prefix_src="--prefix/--all"; else prefix_src=".env PULL_PREFIX"; fi

  warn "no workflow matched — nothing was written."
  [[ -z "$PREFIX" ]] || warn "  configured prefix: '$PREFIX' (from $prefix_src)"
  [[ -z "$ONLY" ]]   || warn "  --only filter:     '$ONLY'"
  if [[ -n "$skipped_slugs" ]]; then
    warn "  $skipped workflow(s) on '$INSTANCE' were skipped:$skipped_slugs"
    warn "  If one of those belongs to this repo, rename it in n8n to carry the"
    warn "  prefix — see docs/adr/0002-workflow-naming.md — then pull again."
  else
    warn "  '$INSTANCE' returned no workflows at all."
  fi
  printf 'error: pull matched 0 workflows\n' >&2
  exit 3
fi

info "review with: git diff workflows/"
