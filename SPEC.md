# SPEC — Build 0a: Git-Backed Workflow Pipeline

**Status:** in progress
**Owner:** Victor Idowu
**Depends on:** nothing
**Blocks:** every subsequent build (0b, 1–6, G1–G5)

---

## Problem

n8n workflows live inside n8n. That is fine until you need any of the things a
portfolio and a production practice actually require:

- A **public repo** showing the workflow JSON (a required artifact for every build).
- A **review trail** — what changed, when, and why.
- **Promotion** of a workflow from one instance to another without rebuilding it by hand.
- **Assurance that no credential ever reaches GitHub.**

Without this, workflows exist only as mutable state in a hosted UI. Build 1 would
produce a demo with nothing to show a reviewer but a screen recording.

## Scope

**In scope (0a):**

1. `scripts/pull.sh` — n8n → repo. Strips credentials. Deterministic output.
2. `scripts/push.sh` — repo → n8n. Merges live credentials back before writing.
3. `--instance` flag on both, so one repo targets multiple n8n instances.
4. `scripts/validate.sh` — the guard. Runs identically locally and in CI.
5. `.github/workflows/validate.yml` — CI gate on every push and PR.
6. Repo conventions: `CLAUDE.md`, `.env.example`, `docs/adr/`.

**Explicitly out of scope (deferred to 0b):**

Docker Compose, queue mode, Redis, Postgres, Traefik, backups, VPS provisioning,
Coolify side services. 0a targets **n8n Cloud only** and requires no server.

## Data flow

```
   n8n Cloud                                          repo (git)
  ┌───────────┐   pull.sh --instance cloud         ┌──────────────────┐
  │ workflows │ ─────────────────────────────────► │ workflows/*.json │
  │           │        strip credentials           │ (no secrets)     │
  │           │        normalise (jq -S)           └────────┬─────────┘
  │           │                                             │
  │           │   push.sh --instance <target>               │
  │           │ ◄───────────────────────────────────────────┘
  └───────────┘        merge live credentials back
                       by node name, then PUT/POST
```

The asymmetry is the whole design. **Pull removes secrets; push restores them from
the target instance's own live state.** Secrets travel from n8n to n8n and never
through git.

## The credential-wipe bug this exists to prevent

`pull.sh` strips `.nodes[].credentials`. Correct — they must never be committed.

But a naive `push.sh` that PUTs the stripped nodes array back **wipes the live
credential bindings on every update**, not just on a fresh instance. The workflow
silently stops authenticating and fails on next execution.

`push.sh` therefore GETs the live workflow first, builds a `node name → credentials`
map from it, and reattaches those bindings before the write.

**Known limitation:** the map is keyed on node **name**. Renaming a node in the repo
drops its binding, and the node arrives unbound. Accepted — it is a one-time fix in
the UI, and `push.sh` reports every unbound node rather than failing silently.

## Instance model

| Instance | Value | Set in `.env` |
|---|---|---|
| `cloud` | n8n Cloud Pro — production runtime | `N8N_CLOUD_URL`, `N8N_CLOUD_API_KEY` |
| `selfhosted` | Hetzner VPS — staging (arrives in 0b) | `N8N_SELFHOSTED_URL`, `N8N_SELFHOSTED_API_KEY` |

`workflows/.index.json` maps each workflow slug to its ID **per instance**. This is
what makes promotion real: the same JSON file has a different ID on each instance,
and the index remembers which is which. Pushing to an instance where the workflow
has no ID **creates** it and records the new ID.

## Division of labour — MCP vs scripts

This is a rule, not a preference:

- **Daily authoring → `n8n_update_partial_workflow` (MCP).** Diff-based and validated.
- **`push.sh` → restore-from-git, bulk deploy, cross-instance promotion only.**

`push.sh` is not an editing path. Using it as one means every edit is a full-workflow
overwrite with no validation.

## Acceptance criteria

Build 0a is done when all of the following are true:

- [ ] `./scripts/pull.sh --instance cloud` writes every Cloud workflow to `workflows/`.
- [ ] No committed file contains a `credentials` object or a secret-shaped string.
- [ ] Running `pull.sh` twice with no changes in n8n produces **zero** git diff.
- [ ] Editing a workflow in the repo and running `push.sh` updates it in n8n **with
      its credential bindings intact** — verified by executing the workflow after.
- [ ] `./scripts/validate.sh` passes locally and the same check gates CI.
- [ ] Deliberately committing a fake credential makes CI **fail**.
- [ ] `README.md` explains setup to someone who has never seen the repo.
- [ ] ADR 0001 records the topology decision and what was rejected.

The third and fifth criteria are the ones that matter. Idempotent pull means diffs
are real signal. A CI gate you have watched fail is a gate; one you have only watched
pass is decoration.

## Failure modes

| Failure | Handling |
|---|---|
| API key missing or wrong | Fail loudly at startup, name the instance and the missing var |
| n8n unreachable | `curl --fail-with-body`, non-zero exit, no partial writes |
| Node renamed between pull and push | Push proceeds; unbound nodes reported by name |
| Workflow absent on target instance | Create it, record the new ID in the index |
| Credential committed by accident | CI fails before merge |
| Two people editing UI and repo at once | Not solved by tooling — see `CLAUDE.md` sync discipline |
