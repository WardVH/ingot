# Product master-data: golden records from contradicting sources

A runnable design exploration for a product master-data model where products are identified by
many codes (EAN/GTIN, CNK, MPN, supplier refs), codes come from **multiple sources that
contradict each other**, and a **priority list** resolves the conflicts into a clean, unique,
**event-sourced** golden record.

It is an *explainer*, not a production system: every file runs with plain `elixir`, no mix
project, no database. The engine is pure data + functions (no GenServers — there's no runtime
state to manage), and history is first-class because the system of record is an append-only
event log.

## Files

| File | What it is |
|------|------------|
| `golden_record_core.ex` | The engine (library): contexts, aggregates, events, resolution, projection. No demo. |
| `golden_record_ddd.exs` | DDD + event-sourced walkthrough — event log, golden as a fold, transaction/valid-time travel, conflict events, steward verdicts. |
| `golden_record_stress.exs` | Stress tests — multiple products + JSON output (Act 1), code collision → shared (Act 2), 3-way contradictions (Act 3), media re-homing on split (Act 4). |
| `golden_record_api.exs` | The customer-facing layer — ATC collections, CNK public identity (canonical + aliases), the read API (resolve-by-code, identity status/redirects, change feed). |
| `golden_record.exs` | The original, pre-DDD procedural version (kept for comparison). |
| `golden_record_test.exs` | ExUnit suite (32 tests) covering GTIN normalization + every engine behaviour. |

```sh
elixir golden_record_ddd.exs        # the guided tour
elixir golden_record_stress.exs     # the hard cases
elixir golden_record_api.exs        # collections, CNK, the read API
elixir golden_record_test.exs       # the test suite
```

## The model in one paragraph

Everything is a **graph of code-identified nodes** (products, variants, media, categories)
joined by **edge-claims** (grouping, classification, hierarchy, media links). Every node and
edge is an immutable, versioned, **bitemporal** claim from some source. Resolution is a pure
function `f(claims, priority) -> golden`, run in two steps: **cluster** the raw evidence, then
**reconcile** clusters to *stable surrogate keys* via an identity cross-reference ledger (the
*xref*) — matched against the evidence, **never** against the golden output. The golden catalog,
the ledger, and the stewardship queue are all just **folds over the log**, so you can replay to
any past point and trace any key's full lineage.

### Key decisions captured here

- **Identity = `(source, scheme, code)`** at the source layer; uniqueness is enforced only at the
  golden layer, where `(scheme, code)` owns one product *unless explicitly marked shared*.
- **Per-dimension priority**: each field/scheme has its own ranked list of source tiers; a tie at
  the top tier is **undecidable → steward review**.
- **Stable surrogate keys** anchored in the xref so identity survives updates; `mint / merge /
  split` are recorded events with lineage. Merges of established keys are **gated** for review,
  never automatic.
- **History is bitemporal**: `valid_from` (true in the world) vs `recorded_at` (when we learned
  it); both are queryable.
- **Normalization before contradiction**: GTIN-family codes (EAN-8/UPC-12/EAN-13/GTIN-14)
  canonicalize to a 14-digit GTIN so equivalent representations stop looking like conflicts.
- **Public identity (CNK)** is *not* the internal key: it's an identity-grade, strictly-unique,
  redirect-on-reassign **alias** of the surrogate key. The API resolves any CNK → surrogate key →
  canonical CNK, so churn underneath stays invisible to customers.
- **Collections (e.g. ATC)** are nodes-with-codes, and membership/hierarchy are **edge-claims** —
  so a collection is the projection of its live edges (union, per-member contradiction, full
  history), and memberships **re-home** through splits/merges exactly like media.
- **The read API** (`Api`/`PublicId`) exposes `resolve_key`/`lookup` (by code, the robust pattern),
  `identity_status` (active / merged→survivor / split→parts) for stale-key redirects, `changes_since`
  (a cursored change feed of identity events), and a CNK uniqueness invariant check.

### Known limits (by design, not bugs)

- Distinguishing "same product, two codes" from "two different products" needs evidence beyond the
  disputed code; absent it, the system raises a **merge-candidate for a steward** rather than
  guessing.
- Aggressive/fuzzy equivalence is **proposed, not auto-applied** — over-normalization (false
  merges) is worse than a visible conflict.
