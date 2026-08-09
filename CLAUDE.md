# Conventions for this repo

## Working style
- Write the ADR before implementing anything non-obvious: three options,
  the choice, what was rejected and why.
- Work in phases. Finish a phase, stop, summarise what changed.
- If something is ambiguous, ask one question rather than assuming.

## Engineering rules
- Every webhook returns 200 before doing any work.
- Every external call has retry with exponential backoff and a dead-letter path.
- Every LLM call is traced to Langfuse with cost, tokens, and latency.
- Every destructive operation is idempotent and reversible.
- Deterministic logic first. Reach for an LLM only for the part that needs one.
- Write the eval before the feature.

## Stack
- Node/TypeScript for services, Python for evals.
- Workflow JSON exported to /workflows, pretty-printed, sorted keys.
- No secrets in workflow nodes. n8n credential store only.

## Sync discipline
- Any MCP write to n8n counts as an out-of-band edit. Run ./scripts/pull.sh
  and commit before touching that workflow's JSON locally.
- Always pull before editing an existing workflow.
- Never edit in the n8n UI and in this repo at the same time.

## Tooling rules specific to this repo
- **Author workflows with the n8n-mcp MCP tools**, not by hand-editing JSON.
  `n8n_update_partial_workflow` is the daily editing path — it is diff-based
  and validated. Hand-edit `workflows/*.json` only for bulk mechanical changes.
- **`push.sh` is not an editing path.** It exists for restore-from-git, bulk
  deploys, and moving a workflow between instances. Reaching for it to make a
  single change means overwriting a whole workflow with no validation.
- Always pass `--instance` explicitly. The default is `cloud`, which is
  production. Never rely on the default when targeting staging.
- Run `./scripts/validate.sh` before every commit. CI runs the same script,
  so a local pass means a CI pass.
- Shell scripts must pass `shellcheck` and start with `set -euo pipefail`.

## Never
- Commit `.env`, any `credentials` object, or a live API key.
- Reformat a workflow JSON by hand — `pull.sh` owns that formatting. If a diff
  looks like pure reformatting, the normalisation changed and that is a bug.
- Add a dependency to the sync scripts beyond `bash`, `curl`, and `jq`.
