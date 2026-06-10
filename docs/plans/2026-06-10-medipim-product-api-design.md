# Product API for medipim — the golden-record service (`api/`)

**Status:** designed 2026-06-10 (brainstorm). Builds on the engine (`lib/golden_record_core.ex`),
the ingest (`lib/ingest/`), the story-demo engine additions (`Stewardship.split`, branch
`story-demo`), and the finer-grained fold prototyped in `temporal_export.exs`.

## Problem

The engine proves the model; medipim still owns product identity. To take over (epic `gr-cdy`'s
endgame) the engine must become a **service** medipim can feed and query: backfill the legacy
history, accept live changes, answer "which product owns this code", and put humans in the loop
for the conflicts the engine refuses to guess on — all without breaking anything that speaks
medipim product IDs today.

## Role — eventual system of record, alongside first

Same API, two phases. **Phase A:** runs alongside; medipim pushes changes and *may* query golden
records and conflicts; its own identity logic stays. **Phase B:** medipim swaps its internal
resolution for API calls. Cutover is a consumer decision — the API doesn't change.

**Backwards compatibility is a hard requirement.** Every golden record carries a **legacy
medipim ID** next to its surrogate key, forever: backfilled records keep their original entity
IDs (via the LegacyXref the ingest derives); products born after the backfill get a freshly
allocated legacy-style ID at first projection. Allocation is recorded as an **event in the log**
(auditable, replayable), not a side table.

## Decisions (settled in brainstorm)

| Fork | Decision | Why |
|------|----------|-----|
| Role | Eventual system of record, run alongside first | Replaces medipim identity with low-risk migration path. |
| Backfill format | Contract-C `HistoryEnvelope` (reused) | Loader + claim mapping built and tested; bead `gr-867`'s PHP endpoint produces it. |
| Backfill granularity | **Finer-grained, per-event dates** (promote the `temporal_export.exs` prototype into `lib/ingest/`) | "Not snapshots — like the demo." Honest identity history; recovers arcs the listing-collapse folds away. |
| Live format | **Engine-native claims** (`POST /v1/claims`) | The claim shape is the real contract; live path shouldn't masquerade as legacy deltas. |
| Storage | **Postgres append-only `events` + `snapshots`** | Durable system of record; snapshots make reads lookups, not folds. First deps (postgrex) — API app only. |
| App shape | **`api/` sibling Mix app, Plug + Bandit** | Like `viz/`: own mix.exs, path dep on the engine; engine stays dependency-free. |
| Packaging | **Docker-native** | Multi-stage `mix release` image + compose with Postgres; Dokploy-ready, env-only config. |
| Surfaces | **Two APIs, one app**: Product API + Steward API | Different consumers, risks, tokens. A leaked medipim token can't approve merges; a steward can't inject product data. |
| Stewardship v1 | Endpoints **+ minimal HTML queue page** | Humans can act from day one (MED-11207 lesson); EEx + form posts, no JS build. |
| Naming | **Product API** (not "item API") | medipim's domain language; `GET /v1/products/{legacy_id}`, `by-code` instead of "resolve". |

## Storage — append-only log + disposable snapshots

- **`events`** `(offset bigserial, payload jsonb, recorded_at, inserted_at)` — the system of
  record. Claims, identity events, flags, steward decisions, legacy-ID assignments. Never
  updated, never deleted; `offset` is the engine's `order` made durable.
- **`snapshots`** — the materialized fold at offset N: identity ledger (members + next-key),
  projected catalog, legacy-ID map, open queue. Write path: load snapshot → fold tail → append +
  store new snapshot **in one transaction**. Reads are snapshot lookups.
- **Disposable:** `mix rebuild` (and an admin endpoint) re-folds from offset 0 and must produce a
  byte-identical snapshot — the integrity check, same trick as the temporal pass's monotonicity
  guard. Suspect snapshot → delete and replay.
- **Single writer:** Postgres advisory lock around fold-append-snapshot. No GenServer, no
  in-memory state; the DB is the synchronization point. Reads never block.
- **Time travel** (`?as_of=`) folds from the log bounded by date — rare, correctness over caching.

## The two APIs

**Product API — `/v1/…`** (medipim, machine-to-machine, `PRODUCT_API_TOKEN`):

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/backfill/envelopes` | Batch of contract-C envelopes; idempotent per envelope (replay = no-op); finer-grained fold. |
| `POST /v1/claims` | Live changes: `[{source, kind, data, valid_from?}]`; fold-forward reconcile; over-merge guard gates live bridges. |
| `GET /v1/products/{legacy_id}` | The backwards-compatible primary read: codes, attributes with provenance, media, identity status. `?as_of=YYYY-MM-DD` for time travel. |
| `GET /v1/products/by-code/{scheme}/{code}` | Which product owns this code; follows merges/splits (`active` / `merged → survivor` / `split → parts`). |
| `GET /v1/changes?since={offset}` | Change feed: mints, merges, splits, steward decisions — medipim reacts by polling. |

**Steward API — `/steward/v1/…` + `/steward` UI** (humans, `STEWARD_API_TOKEN`; basic-auth on
the HTML page):

| Endpoint | Purpose |
|----------|---------|
| `GET /steward/v1/queue` | Open conflicts: merge proposals with bridge codes, attribute ties with candidates. |
| `POST /steward/v1/decisions` | One endpoint, four kinds: `approve_merge`, `reject_merge`, `resolve_attribute`, `split` — 1:1 onto `Stewardship`, recorded with the steward's name. |
| `GET /steward` | Minimal EEx HTML queue page, plain form posts. Same vocabulary as the demo: bridges, candidate duels, tier reasoning. |

Two Plug routers, one Bandit app, shared store. A steward decision is just another event, so the
Product API change feed reports it automatically. Optional env flag binds the steward surface to
a second port for network-level separation. Plus `GET /health` (DB + snapshot offset).

## Errors

- Invalid claim batch → reject whole, `422` with per-claim reasons. Nothing partial enters the log.
- Unknown legacy ID / code → `404`; a `merged`/`split` key answers with where it went — follow, don't error.
- Stale steward decision (already decided) → `409` with current state.
- Postgres down → `503` via `/health`; Docker restarts. One-transaction writes → no partial state.

## Testing

1. **Engine** (existing suite): finer-fold promotion, legacy-ID assignment event + projection.
2. **API contract** (`Plug.Test`, test Postgres): every endpoint, both tokens, auth failures.
3. **End-to-end truth:** backfill the real 422156 fixture over HTTP → projected product equals the
   engine's direct answer → replay the same envelopes → byte-identical (idempotency).
4. **CI:** `services: postgres` + an `api/` job beside the engine matrix.

## Build plan

| # | Task | Depends on |
|---|------|-----------|
| T1 | Engine: promote the finer-grained per-event fold into `lib/ingest/` (+ tests) | — |
| T2 | Engine: legacy-ID continuity — assignment event + projection (xref-backed; allocate above max for new) | — |
| T3 | `api/` scaffold: Mix project, Plug+Bandit, health, token plugs, Dockerfile + compose, CI | — |
| T4 | Event store: schema, fold-append-snapshot transaction (advisory lock), rebuild task | T3 |
| T5 | Product API writes: backfill (idempotent) + live claims (fold-forward) | T1, T2, T4 |
| T6 | Product API reads: products, by-code, as-of, changes | T2, T4 |
| T7 | Steward API + minimal UI | T4 |
| T8 | E2E truth test, `docs/API.md`, READMEs | T5, T6, T7 |
