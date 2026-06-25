# The Product API (`api/`) — golden records for medipim

The engine as a service: medipim feeds product changes in, and reads resolved golden records,
code ownership, and conflicts back. Design: `docs/plans/2026-06-10-medipim-product-api-design.md`.

Two surfaces, one app, separate tokens — a leaked Product token cannot approve merges; a steward
cannot inject product data.

## Auth

| Surface | Paths | Credential |
|---------|-------|------------|
| Product API | `/v1/…` | `Authorization: Bearer $PRODUCT_API_TOKEN` |
| Steward API | `/steward/…` | `Authorization: Bearer $STEWARD_API_TOKEN`, or HTTP Basic (any user, token as password — the browser path for the queue page) |

`GET /health` is unauthenticated (Docker/Dokploy checks): `200 {"status":"ok","db":true}` or `503`.

## Product API

### `POST /v1/backfill/envelopes`

Contract-C `HistoryEnvelope`s (`docs/HISTORY_ENVELOPE.md`), folded **finer-grained** (one dated
identity claim per raw identity event — the honest history, not the listing snapshot).
**Idempotent per envelope**: replaying identical content is a no-op (content fingerprint).

```json
{"envelopes": [ { "schema_version": "1", "legacy_entity": 422156, "events": [...] } ]}
```

`200` → `{"accepted": 1, "skipped": 0, "claims": 213, "events": [...], "flagged": [{"type": "merge_proposal", "keys": ["SK_1","SK_3"]}]}`
— `flagged` is the important part: convergences the over-merge guard **gated** for a steward.
`422` → `{"errors": [{"index": 1, "error": "..."}]}` — the whole batch rejects; nothing partial enters the log.

### `POST /v1/claims`

Live changes, engine-native. Codes are `"scheme:value"` strings (`cnk`, `gtin`/`ean`/`upc`,
`cip_acl7`, `mpn`, …; unknown schemes pass through). `recorded_at` is server-side today;
optional `valid_from` (ISO date) backdates validity.

```json
{"claims": [
  {"kind": "identity",  "source": "medipim", "ref": "P-99", "codes": ["cnk:1234567", "gtin:05410013100072"]},
  {"kind": "attribute", "source": "medipim", "code": "cnk:1234567", "field": "name", "value": "Sunscreen SPF50"},
  {"kind": "media",     "source": "medipim", "asset": "IMG-1", "target": "cnk:1234567", "role": "primary", "uri": "cdn://..."},
  {"kind": "grouping",  "source": "medipim", "code": "cnk:1234567", "product": 422156}
]}
```

Same response shape as backfill. Reconciliation is fold-forward against the live ledger: keys
stay stable, and a claim bridging two **established** keys produces a flagged proposal — never an
automatic merge.

Optional `Idempotency-Key` header: replaying the same key with the same claims returns the original
response without appending; reusing the key with different claims returns `409`.

### `POST /v1/cutover`

Commit a **migration batch** — the explicit cutover of the dry-run → fix mapping → cutover loop.
Same body as `/v1/claims`, but with migration semantics: the batch is the source's **current
truth**, so only the last claim per slot counts (non-final slot history is compacted, counted in
`counts.compacted`), which makes re-runs **convergent** — an identical re-run appends zero events
and churns zero keys; a changed re-run supersedes only its own slots. `200` → the committed
migration report (the dry-run's sections — mints, merge candidates, conflicts, collisions, the
seeded steward queue — now describing the committed world) plus `lineage`: the legacy-id
assignments this commit recorded. `422` → the whole batch rejects; a cutover commits whole or
not at all. Decision rationale in `Api.Cutover`'s moduledoc.

### `GET /v1/products/{legacy_id}`

The backwards-compatible primary read — every golden record answers to a legacy medipim ID
forever (backfilled records keep theirs; new products get one allocated above the max at first
projection).

`200` → key, sorted codes, attributes with full provenance (`value`, `winner`, `status`,
`candidates`), media, `status`, and `merged_from` when the id belonged to a key that was merged
away (the id keeps answering — followed to the survivor). `404` → unknown id.

`?as_of=YYYY-MM-DD` — the product as **known on** that date (folds the log, bounded by date);
`404` with `as_of` echoed when the product wasn't resolvable yet.

### `GET /v1/products/by-code/{scheme}/{code}`

Which product(s) own this code — any spelling (an EAN-13 finds the stored GTIN-14). Returns
`{"code": "<canonical>", "products": [...]}`; a legitimately shared code returns every carrier.

### `GET /v1/changes?since={offset}&limit={n}`

The polling feed: every event after `offset` (claims, mints, members changes, merges, splits,
merge proposals, steward decisions, legacy-id assignments), each with its `offset`; `next` is the
cursor for the following call.

## Steward API

### `GET /steward/v1/queue`

`{"merges": [{"keys": [...], "bridge": [...], "members": {...}}], "attributes": [{"key", "field", "candidates"}], "open": n}`
— gated merge proposals (with the bridging codes) and attribute ties the engine refuses to guess on.

### `POST /steward/v1/decisions`

One endpoint, four kinds — recorded in the log with `by` (the steward's name):

```json
{"kind": "approve_merge",     "keys": ["SK_1","SK_3"], "by": "sam"}
{"kind": "reject_merge",      "keys": ["SK_1","SK_3"], "by": "sam"}
{"kind": "resolve_attribute", "key": "SK_1", "field": "color", "value": "ivory", "by": "sam"}
{"kind": "split",             "key": "SK_1", "codes": ["gtin:08712345678906"], "by": "sam"}
```

A split immediately allocates the carved-out key its own legacy id; attributes and media re-home
by code on the next read — nothing re-imported. Stale decisions (keys no longer live, proposal
already decided) answer `409` with the live keys. The decision appears on the Product change feed
like any other event.

### `GET /steward` — the queue page

Server-rendered HTML (no JS): proposals with approve/reject, ties with a pick form, a split form.
Open it in a browser; HTTP Basic prompts for the steward token.

## Operations

- **Run locally:** `docker compose -f api/docker-compose.yml up --build` (from the repo root) —
  Postgres + the API on `:4000`.
- **Env (prod):** `DATABASE_URL`, `PRODUCT_API_TOKEN`, `STEWARD_API_TOKEN`, `PORT` (4000),
  optional `STEWARD_PORT` — set it and the steward surface binds its own listener while the main
  port stops serving `/steward` (network-level separation). Optional limits:
  `MAX_CLAIMS_PER_BATCH` (default `10000`) and `MAX_ENVELOPES_PER_BATCH` (default `1000`).
  Optional survivorship config: `SOURCE_PRIORITY_JSON`, e.g.
  `{"fields":{"name":[["manufacturer"],["supplier"]]},"default":[["manufacturer"],["supplier"]]}`.
- **Storage:** append-only `events` (the system of record) + a disposable snapshot. Append and
  snapshot are one transaction under an advisory lock; reads never block.
- **Integrity:** `Api.Store.rebuild!/0` (iex/release rpc) re-folds the entire log from zero and
  verifies the snapshot — `{:ok, offset}` healthy, `{:repaired, offset}` if the snapshot had
  drifted (the log always wins).
- **Tests:** `cd api && mix test` (needs Postgres, e.g.
  `docker run -d --name gr-api-test-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine`).
  The end-to-end truth suite asserts the HTTP answers EQUAL the engine's direct answers for the
  real 422156 fixture.
