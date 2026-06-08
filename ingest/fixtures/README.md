# Ingest fixtures

## `medipim_be_422156.*` — real legacy entity 422156

The full delta history of one real medipim product (legacy `entity` 422156, an Aderma Primalba
wash gel), used as the PoC fixture for the ingest pipeline. It is **real data**, not synthetic.

| file | what |
|------|------|
| `medipim_be_422156.raw.jsonl` | **Ground truth.** 1676 real `products_deltas` rows, one JSON object per line, time-ordered, undecoded. Exactly as stored in medipim (`[opcode, key, value]` event triples). No decode decisions baked in. |
| `gen_422156.exs` | The decoder/**oracle** that applies contract-C decode rules to the raw dump and emits the envelope. One-off fixture tooling — **not** the runtime ingest (see below). |
| `medipim_be_422156.json` | The decoded-but-unresolved **`HistoryEnvelope`** (contract C). Generated from the raw dump by `gen_422156.exs`. This is what the ingest pipeline consumes and what medipim's future PHP endpoint (bead gr-867) must reproduce. |

Regenerate the envelope after editing decode rules:

```bash
elixir ingest/fixtures/gen_422156.exs
```

### Provenance

Exported 2026-06-08 from a production dump (`medipim_db_08-06-2026...csv`) loaded into the local
`medipim2-mysql` Docker container (`medipim_test.products_deltas`, FK checks off — only the deltas
were needed). The raw JSONL is a faithful re-export of those 1676 rows as utf8mb4.

### Why a one-off oracle and not the production loader

Contract C keeps medipim's decode (`ProductDeltaApplier`/meta) on medipim's side of the wall; the
production system-of-record ingest consumes envelopes emitted by medipim's own PHP endpoint
(gr-867), reusing battle-tested code. `gen_422156.exs` exists **only** to bootstrap this committed
fixture from a one-time dump. Its output *is* the contract the endpoint must match — so when gr-867
is built, diff its emitted envelope for 422156 against `medipim_be_422156.json` to validate.

### Shape of this fixture (decoded)

- **930 events** kept — 23 identity, 127 attribute, 12 edge, 768 media.
- **819 touch-only deltas dropped** (`dropped_meta_count`); `last_touched_at` preserved.
- **Media churn dominates** (≈82% of events are `media` add/remove of asset ids). It is faithful
  to the log but pure noise for identity re-derivation; downstream clustering ignores it.

### The identity story (why 422156 is a good fixture)

All three source orgs (1034, 1035, 44) converge on **CNK `3612173`** and canonical GTIN
`03282770146004`, but **not at the same time** — org 44 began divergent (a different EAN
`3282770049374`, no CNK) and only converged its EAN in 2023-08 and its CNK in 2024-03. A snapshot
fold sees one clean cluster ("legacy was right"); the temporal pass recovers *when* org 44 merged
in. The history also exercises the GTIN scheme migration (`ean`→`eanGtin13`→`eanGtin14`), an op-4
delete, and 2026 set-null cleanups.

### Classification decisions (see `gen_422156.exs` for the authoritative map)

- `legacyId` (medipim's own previous-system id) → dropped as meta; it is not a product code.
- `organizations` → `edge` (structural; derivable from per-source events, may be ignored downstream).
- `update_sources` opcode → dropped (a survivorship recompute, not a data change).
