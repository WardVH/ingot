# Ingesting legacy medipim history → golden records

**Date:** 2026-06-05
**Status:** Validated design, ready for implementation
**Repos:** `brainstorming-experiments` (this engine, Elixir) · `baldwin/medipimv2` (legacy source, PHP)

## Goal

Make this golden-record engine the **system of record** that takes over from medipim's
legacy product-master-data approach. The legacy system already does per-source storage and
survivorship (`SourcesRanker` + per-field `sourceScores`), but it never did principled
**identity resolution**: which org listings are the same real product was decided by an
implicit/by-code/manual process during import and then frozen as the `entity` id — with no
surrogate keys, no merge/split lineage, no collision detection, no gating.

We re-derive identity from the codes themselves, produce real **golden records**, and keep a
durable **legacy → new** cross-reference so every existing `entity` id still resolves after
cutover (even when it splits).

medipim's history export is **just the feed** — a data pipe. It is not authoritative.

## Architecture

```
medipim (PHP)                         │  this repo (Elixir) — system of record
──────────────────────────────────────────────────────────────────────────────
products_deltas                       │
   │ decode via meta-fields           │
   ▼                                  │
[ HistoryEnvelope ]  ─── JSON ──────▶ │  ingest pipeline
 decoded, UNRESOLVED                  │     fold → claims → canonicalize+partition
 (no folding, no survivorship);       │        → cluster → reconcile
 legacy `entity` rides along          │            │
 as metadata only                     │            ├─▶ GOLDEN RECORDS (Catalog/Api) + go-forward log
                                      │            └─▶ LegacyXref (legacy ⟷ surrogate key)
                                      │                   └─ relation ∈ {stable, split, merged}
                                      │                      == the migration diff, for free
```

### Decisions

- **Re-derive identity (distrust the legacy grouping).** Cluster by shared codes; the legacy
  `entity` is never a clustering input.
- **Produce golden records (option X — fresh re-derivation).** Golden records are whatever the
  codes say. Identity changes auto-apply at migration; the xref *records* what changed rather
  than gating it beforehand. (Option Y — seeding the ledger with legacy entities so
  disagreements come out gated — was considered and rejected for now: the user wants the codes
  to win, with after-the-fact review via the xref's `relation`.)
- **Contract C — decoded-but-unresolved event stream.** medipim owns its own quirks (opcode/key
  grammar, `eanGtin13_` value prefixes, locale/org parsing, dropping touch-only deltas). This
  engine owns 100% of resolution (canonicalization, folding, clustering, survivorship). The
  legacy `entity` is carried only as the audit/xref baseline.
- **Build PoC-first.** Prove the loop in Elixir against a fixture of the real entity `422156`
  history before writing any PHP. The fixture *is* the contract the endpoint will later emit.

- **Decode stays in medipim — reading MySQL directly was considered and rejected (2026-06-08).**
  A direct Elixir MySQL adapter over `products_deltas` would skip the PHP endpoint, but it means
  re-implementing medipim's decode (`ProductDeltaApplier`/meta: opcode/key grammar,
  `eanGtin13_`/`eanGtin14_` value-prefix stripping, field→scheme/kind, touch-only dropping) from
  scratch in a second language — a correctness risk on the exact quirk-handling that contract C
  exists to isolate. We keep the decode in medipim (it reuses its own battle-tested code) and
  consume `HistoryEnvelope` over the endpoint. The PoC still runs on the hand-translated fixture.

## The `HistoryEnvelope` (contract C)

One envelope = one legacy entity. The ingest accepts a **list** of envelopes and clusters across
all of them (that is how cross-entity merges surface). Events are a **flat, time-ordered,
granular** list — faithful to the delta log, with no folding into code-sets and no survivorship.

```json
{
  "schema_version": "1",
  "source_system": "medipim-be",
  "legacy_entity": 422156,
  "last_touched_at": 1749646919,
  "dropped_meta_count": 540,
  "events": [
    {"recorded_at":1535726805,"valid_from":1535726805,"by":2,"tag":"import_871",
     "source":"1034","op":"set","kind":"identity","scheme":"cnk","code":"3612173"},
    {"recorded_at":1542628648,"by":2,"tag":"import_929",
     "source":"44","op":"add","kind":"identity","scheme":"ean","code":"3282770049374"},
    {"recorded_at":1692888552,"by":4573,"tag":"product_update",
     "source":"44","op":"remove","kind":"identity","scheme":"ean","code":"3282770049374"},
    {"recorded_at":1706722540,"by":4081,"tag":"import_4968",
     "source":"1034","op":"delete","kind":"identity","scheme":"eanGtin13"},
    {"recorded_at":1536088674,"by":11,"tag":"import_872",
     "source":"1035","op":"set","kind":"attribute","field":"name","locale":"fr","value":"ADERMA …"},
    {"recorded_at":1536765705,"by":134,"tag":"product_update",
     "source":null,"op":"add","kind":"media","asset":158717}
  ]
}
```

### `kind` taxonomy → engine claim

| kind        | medipim source                          | engine target                       | role in re-derivation |
|-------------|-----------------------------------------|-------------------------------------|-----------------------|
| `identity`  | cnk, ean, gtin, eanGtin8/12/13/14       | identity claim codes                | **drives clustering** |
| `attribute` | name, status, price, tax, dims, …       | attribute claim (anchored to code)  | survivorship only     |
| `edge`      | publicCategories, brands, labos         | member_of claim                     | re-homes; not identity |
| `media`     | media, descriptions                     | media claim                         | noise for identity    |
| `meta`      | `updatedAt`/`updatedBy`-only deltas      | **dropped at the endpoint**         | ~90% volume reduction |

### medipim opcode → `op`

`1` → `set` (scalar) · `2` → `add` (collection) · `3` → `remove` (collection) ·
`4` → `delete` (drop a whole source entry for a scheme, e.g. `["4","eanGtin13",1034]`).

### Dropping touch-only deltas

Deltas that reduce to nothing but `updatedAt`/`updatedBy` carry no identity/attribute/edge
signal and are the bulk of the volume, so the endpoint drops them. Two things are preserved:
`updatedAt`/`updatedBy` riding *alongside* a real change become that event's `recorded_at`/`by`;
and the product's true `last_touched_at` (max over all deltas, including dropped ones) is kept at
the envelope level — it is the trigger signal that tells a manufacturer/pharmacist "your product
changed, go look." `dropped_meta_count` records how many rows were filtered.

## Ingest pipeline (Elixir)

```
envelopes ─▶ fold ─▶ build claims ─▶ canonicalize+partition ─▶ cluster ─▶ reconcile
                                                                             ├─▶ golden records
                                                                             └─▶ LegacyXref
```

1. **Fold (per listing).** A *listing* = `(legacy_entity, source)`. Replay its granular identity
   events (`set`/`add`/`remove`/`delete`, in `recorded_at` order) into a final code-set.
   `delete` drops that source's whole scheme entry (the opcode-4 case). (Snapshot semantics for
   v1 — see Temporal pass below.)

2. **Build claims.**
   - identity → `%{ref: "ent:src", codes: [{scheme, code}, …]}` — one per listing, its code-set.
   - attribute → `%{code: anchor, field, value}` — anchored to the listing's primary code
     (CNK ▸ canonical GTIN ▸ first code).
   - edge → `%{member_code: anchor, collection}`.
   - grouping (synthesized) → `%{code, product: legacy_entity}` — makes the legacy entity a
     first-class "product label" for collision reasoning.

3. **Canonicalize + partition.** Run every code through `Codes.canonicalize` (GTIN family →
   GTIN-14). Split schemes into **bridging** (CNK, non-restricted GTIN) vs **non-bridging /
   shared** (`Codes.restricted?` in-store GTINs, MPN/supplierReference). Non-bridging codes ride
   along via the engine's `shared` set so they never fuse two products.

4. **Cluster + reconcile.** `Cluster.variants(claims, shared)` ignores `legacy_entity` entirely;
   `IdentityLedger.decide` mints surrogate keys.

5. **Project golden records.** `Catalog.project` / `Api` over the re-derived log: products →
   variants → resolved attributes (survivorship), codes, CNK canonical+alias, media, categories.
   Plus the go-forward event log so history, time-travel, and CNK redirects work natively.

## `LegacyXref` — the durable legacy → new map

`legacy_entity` stays **metadata on each listing**, never a clustering code (it must not bridge).
After clustering, fold into two maps:

```
key_to_legacy:  SK_1   → [422156]              # provenance: which legacy entities this descends from
                SK_2   → [555001, 555002]       # a merge absorbed two legacy entities
legacy_to_key:  422156 → {primary: SK_1, all: [SK_1],       relation: :stable}
                555001 → {primary: SK_2, all: [SK_2],       relation: {:merged, [555002]}}
                700300 → {primary: SK_5, all: [SK_5, SK_6], relation: :split}
```

- **Split → one primary.** When a legacy entity lands on >1 key, pick a deterministic primary by
  reusing the engine's split "keep" heuristic: prefer the sub-cluster with an identity spine
  (CNK ▸ GTIN), then most listings, then lowest key. The rest are kept in `all`.
  `resolve_legacy(700300)` → `{:ok, SK_5, {:split, [SK_5, SK_6]}}` — answer with the primary,
  disclose the alternates. Mirrors how a stale CNK redirects today.
- **The diff falls out for free.** `relation ∈ {:stable, :split, :merged}` (plus
  `PublicId.collisions/2` for a CNK still on >1 key) *is* the audit classification
  (confirm / split / merge / collision). No separate diff machinery.

## Sanity check on entity 422156

All three listings converge on CNK `3612173` **and** GTIN `03282770146004` → one cluster → one
surrogate key → `relation: :stable` ("legacy was right"). Quiet but correct, and it proves the
loop end-to-end. (The richer story — org 44 carried a *different* EAN and no CNK until 2023–24,
so it only *became* the same product over time — is invisible to a snapshot and motivates the
temporal pass.)

## Temporal pass (follow-up, not v1)

v1 folds each listing to its **final** code-set (a snapshot). A later pass replays the envelope
through time, re-clustering at each delta, to emit the full identity history (mint/merge/split
events with real `created_at`), recovering *when* identity changed — e.g. the 2023–24 moment org
44 merged into 422156. The same envelope feeds both; only the fold changes.

## Build order

1. `HistoryEnvelope` schema + a committed fixture hand-translated from the real `422156` deltas.
2. Elixir ingest + golden records + `LegacyXref` against that fixture.
3. Synthetic envelopes (a fragmented entity → split, two entities sharing a CNK → merge, a
   contradictory CNK → collision) so the diff demonstrably finds something. ExUnit tests.
4. PoC demo script (`golden_record_ingest.exs`) printing golden records + xref + diff.
5. **Phase 2:** the medipim PHP endpoint that emits real `HistoryEnvelope`s from
   `products_deltas`, reusing meta-fields to decode and dropping touch-only deltas. The same
   Elixir ingest then points at its output.
