# ADR 0001 — n8n deployment topology

**Date:** 2026-08-09
**Status:** Accepted
**Context:** Build 0a / 0b

## Context

Every workflow in this portfolio needs somewhere to run. That runtime choice
determines what infrastructure work is possible, what it costs, and what can
honestly be claimed on a CV.

Two constraints shape the decision:

1. An n8n Ambassador grant provides **n8n Cloud Pro free for 12 months**.
2. Docker / queue mode / reverse proxy / backups is the **largest named gap**
   against the target job descriptions.

These pull in opposite directions. Cloud removes the cost argument for
self-hosting; the skills gap removes the convenience argument for Cloud-only.

## Options considered

### Option A — Cloud only

Everything on n8n Cloud Pro.

- **For:** zero infrastructure work, zero cost for 12 months, managed TLS,
  always-on webhooks, no maintenance burden, fastest path to a shippable Build 1.
- **Against:** leaves the single biggest JD gap wide open. Cannot host WAHA,
  Chatwoot, Langfuse, Metabase, or Uptime Kuma. No staging environment, so
  every change is tested in production. Nothing to say when an interviewer asks
  about queue mode or disaster recovery.

### Option B — Self-hosted only

Everything on a Hetzner VPS in queue mode.

- **For:** closes the infrastructure gap completely. Full control. Hosts every
  side service. Cheapest at high volume.
- **Against:** wastes a free Cloud Pro grant. Puts client-facing voice and
  WhatsApp webhooks on infrastructure maintained by one part-time student —
  a 3am outage becomes a portfolio liability rather than an asset. Roughly 25
  hours of infrastructure work before a single portfolio-visible artifact exists.

### Option C — Hybrid: Cloud for production, self-hosted for staging and services

**Chosen.**

- **For:** uses the grant for what it is good at (always-on client-facing
  webhooks under an implied SLA) and self-hosting for what it is good at
  (engineering proof, staging, and hosting services Cloud cannot run). Produces
  a stronger claim than either alone — operating a promotion pipeline across two
  instances is a materially different skill from running one.
- **Against:** two environments to keep in sync, which is precisely the problem
  Build 0a exists to solve. Real added complexity, accepted deliberately.

## Decision

**Option C, built in two phases rather than one.**

The original plan treated Build 0 as a single 20–25 hour unit executed before
anything else. Splitting it:

- **0a — git sync + CI (~6h, week 1).** Cloud only, no server required.
- **0b — VPS, queue mode, Traefik, backups (~18h, weeks 6–8).** Runs in the
  background while applying.

### Why split

The two halves have very different dependency profiles.

**0a is load-bearing and urgent.** Every build owes a public repo containing
exported workflow JSON. Without the sync pipeline, Build 1's workflows exist only
as mutable state in a hosted UI, and version control gets retrofitted onto three
builds at once later — the expensive kind of debt.

**0b is load-bearing but not urgent.** Nothing in Build 1 requires it: Langfuse
has a free cloud tier, so does Chatwoot. WAHA is the only genuinely self-host-only
component, and it is the *secondary* option in Build 2, not the primary.

Front-loading all of Build 0 delays the public phone number — the strongest single
proof artifact available — by roughly two weeks, in exchange for infrastructure no
build needs yet. The build plan's own closing section argues for visible shipping
cadence over a finished catalogue; front-loading invisible infrastructure
contradicts it.

## Rejected, and why it stays rejected

**Deleting 0b entirely** was considered, since the free Cloud grant makes it
technically unnecessary for 12 months.

Rejected. The infrastructure gap is the hardest thing here to fake in an
interview, and the résumé claim requires a *tested restore* and a *demonstrated*
worker failover — neither of which can be written retrospectively. "Kill a worker
mid-execution, job completes anyway" is a 20-second clip that ends an entire line
of questioning. Deferred, not dropped.

## Consequences

- The sync scripts need an `--instance` flag from day one, even though only one
  instance exists during 0a. Retrofitting it later means rewriting both scripts
  and every call site.
- `workflows/.index.json` tracks per-instance IDs, because the same workflow has
  a different ID on each instance.
- Credentials must never traverse git, so `push.sh` merges them from the target
  instance's live state. See `SPEC.md`.
- Promotion direction is **staging → production** once 0b lands. Until then,
  `cloud` is the only valid target and it is production. The scripts default to
  `cloud`, which is the dangerous default — `CLAUDE.md` requires `--instance` to
  be passed explicitly for exactly this reason.
