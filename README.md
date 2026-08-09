# automation-platform

Git-backed pipeline for n8n workflows. Pulls workflows out of n8n with credentials
stripped, validates them in CI, and pushes them back with credential bindings
intact — across more than one n8n instance.

This is **Build 0a** of an AI automation portfolio. It is the substrate every other
build sits on: each of those owes a public repo containing its exported workflow
JSON, and this is what produces it safely.

---

## The problem it solves

Workflows live inside n8n as mutable state in a hosted UI. That blocks version
control, code review, and any honest promotion story between environments.

The obvious fix — export the JSON to git — has a trap in it. Workflow JSON contains
credential references, so a naive export leaks secrets. Strip them, and a naive
re-import **wipes the live credential bindings on every update**, silently breaking
authentication until someone notices a failed execution.

The design here is deliberately asymmetric:

```
   n8n instance                                      repo (git)
  ┌───────────┐   pull.sh --instance cloud        ┌──────────────────┐
  │ workflows │ ────────────────────────────────► │ workflows/*.json │
  │           │       strip credentials           │ (no secrets)     │
  │           │       normalise (jq -S)           └────────┬─────────┘
  │           │                                            │
  │           │   push.sh --instance <target>              │
  │           │ ◄──────────────────────────────────────────┘
  └───────────┘       merge live credentials back
                      by node name, then PUT/POST
```

**Secrets travel n8n → n8n and never through git.**

---

## Setup

Requires `bash`, `curl`, and `jq`. Nothing else.

```bash
sudo apt install -y jq          # if you don't have it

git clone <this repo> && cd automation-platform
cp .env.example .env
```

Get an API key from n8n: **Settings → n8n API → Create an API key.** Keys are
instance-specific. Put it in `.env`:

```bash
N8N_CLOUD_URL=https://your-instance.app.n8n.cloud
N8N_CLOUD_API_KEY=n8n_api_...
```

Then:

```bash
./scripts/pull.sh --instance cloud     # n8n → repo
./scripts/validate.sh                  # the guard
git add -A && git commit -m "pull workflows"
```

---

## Scripts

| Script | Direction | Use it for |
|---|---|---|
| `pull.sh` | n8n → repo | After **any** change made in the UI or via MCP |
| `push.sh` | repo → n8n | Restore-from-git, bulk deploy, cross-instance promotion |
| `validate.sh` | — | Before every commit. CI runs the identical script |

All accept `--instance cloud\|selfhosted` and `--only <slug>`. `push.sh` also takes
`--dry-run`, which reports what it would do and writes nothing.

```bash
./scripts/pull.sh --instance cloud
./scripts/pull.sh --instance cloud --only dispatch-desk-intake
./scripts/push.sh --instance selfhosted --dry-run
./scripts/push.sh --instance selfhosted --only dispatch-desk-intake
```

### `push.sh` is not an editing path

Use `n8n_update_partial_workflow` from the n8n-mcp MCP server for daily authoring —
it is diff-based and validated. `push.sh` overwrites a whole workflow with no
validation, which is right for a restore and wrong for a one-line change.

### The default instance is production

Both scripts default to `--instance cloud`, which is the production runtime.
`push.sh` prints a warning and waits 5 seconds before writing there. Pass
`--instance` explicitly, always.

---

## How instances work

`workflows/.index.json` maps each workflow slug to its ID **per instance**:

```json
{
  "dispatch-desk-intake": {
    "name": "Dispatch Desk — Intake",
    "cloud": "AbC123",
    "selfhosted": "XyZ789"
  }
}
```

The same file has a different ID on each instance. The index remembers which is
which — that is what makes promotion real rather than aspirational. Pushing to an
instance where a workflow has no ID **creates** it (after first trying to match an
existing workflow by name, so you don't get duplicates) and records the new ID.

A newly created workflow arrives **inactive and with unbound credentials**, by
design. Bind them once in the UI.

---

## The node-rename limitation

Credential merging is keyed on node **name**. Rename a node in the repo and its
binding is dropped — the node arrives unbound.

This is accepted rather than solved. `push.sh` reports every affected node by name
at the end of its run, so it is loud rather than silent, and it is a one-time fix in
the UI. Solving it properly would mean keying on node `id`, which is not stable
across instances and would break promotion — the more valuable property.

---

## What CI enforces

`.github/workflows/validate.yml`, on every push and PR:

1. **Workflow JSON** — parses, has the required shape, contains **no** `credentials`
   object, contains no secret-shaped strings, and is normalised.
2. **shellcheck** on every script.
3. **`.env` is not tracked** — `.gitignore` can be bypassed with `git add -f`; this
   catches it.

Check 1's normalisation rule is what makes diffs trustworthy: if a diff shows only
reformatting, the normaliser changed and that is a bug.

---

## Repo layout

```
automation-platform/
├── README.md
├── CLAUDE.md              conventions for AI-assisted work in this repo
├── SPEC.md                written before the code
├── .env.example
├── docs/adr/              one file per architectural decision
├── workflows/             exported n8n JSON, credentials stripped
│   └── .index.json        slug → per-instance ID map
├── scripts/
│   ├── lib.sh             shared helpers
│   ├── pull.sh
│   ├── push.sh
│   └── validate.sh
└── .github/workflows/     CI
```

---

## Scope

**In:** the sync pipeline and its CI gate, targeting n8n Cloud.

**Out — deferred to Build 0b:** Docker Compose, queue mode, Redis, Postgres,
Traefik, backups, VPS provisioning. This build needs no server. See
[ADR 0001](docs/adr/0001-n8n-deployment-topology.md) for why the two were split.
