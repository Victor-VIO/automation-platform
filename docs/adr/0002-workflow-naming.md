# ADR 0002 — Workflow naming and per-build scoping

**Date:** 2026-08-11
**Status:** Accepted
**Context:** Build 0a, and every build after it

## Context

One n8n Cloud instance serves the entire portfolio. Every build — 0a, 1 through
6, G1 through G5 — creates workflows in the same account, and each build has its
own repo.

That makes an unscoped pull actively wrong. `pull.sh` writes one file per
workflow into `workflows/`, so without a filter every repo would pull every other
build's workflows, commit them, and validate them. Three builds in, each repo
contains the union of all three, and `git diff` stops meaning anything.

`pull.sh` already has a `--prefix` flag and a `PULL_PREFIX` default. What it has
never had is a stated convention for what those prefixes are or when they get
applied. The Build 0a audit found the consequence: `.env` shipped
`PULL_PREFIX=ap-`, no workflow on the instance was named to match, and
`./scripts/pull.sh --instance cloud` silently pulled zero workflows and exited 0.
The filter worked exactly as written. Nothing had been named for it.

A scoping mechanism without a naming convention is a filter that matches nothing.

## Options considered

### Option A — Per-build prefix in the workflow name, applied at creation

Every workflow this repo owns is named `AP — <Descriptive Name>`. `slugify()`
collapses any run of non-alphanumeric characters to a single `-`, so
`AP — Dispatch Desk Intake` becomes the slug `ap-dispatch-desk-intake`, and the
file `workflows/ap-dispatch-desk-intake.json`.

- **For:** the scope marker lives in the one field that already survives
  everything — it is in the API list response, in the normalised JSON, in the
  filename, in the git history, and visible in the n8n UI sidebar without
  clicking in. Costs one API call, the one `pull.sh` already makes. Works
  identically on Cloud and self-hosted, so it survives Build 0b. A human
  scanning the n8n workflow list can see which build owns what.
- **Against:** the prefix is carried by a mutable string. Renaming a workflow
  changes its slug and therefore its filename, so renames need a defined
  procedure (below). Names get slightly longer and slightly uglier.

### Option B — n8n tags

Tag each workflow with its build (`build-0a`, `build-1`) and filter the pull on
tag rather than on name.

- **For:** immune to renames — the tag is independent of the name. The n8n API
  supports tag filtering directly. Names stay clean.
- **Against:** rejected on two counts. First, tags are instance-side metadata
  and are **not** part of the normalised workflow JSON this repo commits
  (`normalise_workflow` keeps only `name`, `nodes`, `connections`, `settings`).
  A workflow promoted to another instance by `push.sh` arrives with no tags, so
  the scoping marker is precisely the thing that does not survive promotion —
  and promotion is the property ADR 0001 chose the hybrid topology to get.
  Second, the marker becomes invisible where it is most needed: a filename in
  git tells you nothing about which build owns it.

### Option C — A separate n8n project per build

Use n8n's projects feature, give each build its own, and filter pulls by
`projectId`.

- **For:** the strongest isolation of the three. Enforced by the platform rather
  than by convention, so it cannot be got wrong by typing a name carelessly.
- **Against:** rejected. It binds the repo layout to a Cloud plan feature, and
  0b's self-hosted instance would have to reproduce the same project structure
  or the promotion path breaks. It also puts the scope marker in an opaque ID
  that means nothing in a filename or a diff, which is Option B's second problem
  with an extra dependency attached.

## Decision

**Option A. A short per-build prefix, applied when the workflow is created.**

This repo's prefix is **`ap-`** (automation-platform), which is what `.env`
already carries. The convention:

| Rule | Value |
|---|---|
| Prefix for this repo | `ap-` |
| Workflow name form | `AP — <Descriptive Name>` |
| Resulting slug | `ap-<descriptive-name>` |
| Resulting file | `workflows/ap-<descriptive-name>.json` |

The separator between prefix and name does not matter — `AP — Name`, `AP - Name`
and `[AP] Name` all slugify identically, because `slugify()` collapses every run
of non-alphanumeric characters into one `-`. What matters is that the slug's
**first dash-delimited segment is exactly `ap`**.

Prefix matching is delimiter-aware: `ap-` matches `ap-intake`, and does **not**
match `api-gateway` or `apple-sorter`. Matching on the bare string `ap` would
capture both of those. The prefix is a whole leading segment, not a substring.

**Applied at creation time, not retrofitted.** A workflow created without the
prefix is invisible to this repo's pull until someone renames it. Naming it
correctly in the n8n UI or in the MCP `create` call is a two-second act; noticing
six weeks later that a workflow was never version-controlled is not.

## What happens when a workflow is renamed

The slug is derived from the name, so **a rename changes the filename**. The n8n
workflow ID does not change, which is what makes the recovery clean.

Renaming is a deliberate three-step operation, not a side effect:

1. Rename in n8n (UI or MCP).
2. `./scripts/pull.sh --instance cloud` — writes the workflow to its **new**
   `workflows/<new-slug>.json` and records `<new-slug> → id` in `.index.json`.
3. `git rm workflows/<old-slug>.json` and drop the stale `<old-slug>` key from
   `workflows/.index.json`.

Step 3 is manual and currently unavoidable: `pull.sh` never deletes files, so the
old file stays behind, still listed in the index against the same live ID. Two
slugs pointing at one workflow is a genuine hazard — `push.sh` iterates over
`workflows/*.json`, so a stale file would be pushed back up and, matching by name,
could overwrite the renamed workflow with its previous contents.

Until `pull.sh` learns to prune, **a rename is not complete until the old file and
its index entry are gone.** Review `git status` after every rename; an untracked
or deleted-but-unstaged file in `workflows/` after a pull means a rename is
half-finished.

**Never rename across the prefix boundary.** Changing `AP — Intake` to
`Intake` removes the workflow from this repo's scope entirely: the next pull
skips it, the file is never updated again, and nothing reports an error, because
from the pull's point of view the workflow simply does not exist. Changing the
prefix is a migration between repos, not a rename.

## What a newcomer does with an unprefixed workflow

Inheriting a workflow that predates this convention — the Build 0a audit found
two — the question is whether the workflow belongs to this repo at all.

**If it belongs here:** rename it in n8n to add the prefix, then pull. The ID is
stable across the rename, so the index picks it up under the new slug on the next
pull. If a file already existed under the old slug, remove it and its index entry
as in step 3 above. This is the only supported adoption path.

**If it does not belong here:** leave it alone. It belongs to another build, or
to no build. Do not pull it, do not commit it, and do not delete it from the
instance without checking its execution history first — an unprefixed workflow
with real executions is somebody's running system.

**If it belongs here but genuinely cannot be renamed** — a live webhook whose
name is load-bearing somewhere external — pull it once with an explicit
`--prefix` or `--all` override and commit the result, then open an issue. Be
clear about what that costs: routine `pull.sh` runs will keep skipping it, so it
is version-controlled once and then silently drifts. It is a stopgap with a known
expiry, not a steady state.

## Consequences

- `.env.example` ships `PULL_PREFIX=ap-`, and a newcomer following the README
  gets a correctly scoped pull without configuring anything.
- A pull that matches **zero** workflows is now an error, not a silent success.
  With a convention in place, zero matches means the prefix is wrong, the
  workflows were misnamed, or something was deleted upstream — all three want a
  human. See the exit-code decision recorded in the `pull.sh` commit.
- `push.sh` remains scoped by file, not by prefix. It pushes what is in
  `workflows/`, and the prefix convention is what keeps foreign workflows out of
  that directory in the first place.
- Every future build repo picks its own prefix and writes it into its own
  `.env.example`. Prefixes must not be substrings of one another where one is a
  whole leading segment of the other — `ap` and `ap2` are fine because matching
  is segment-wise, but two builds must never share a prefix.
