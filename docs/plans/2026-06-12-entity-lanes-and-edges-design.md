# First-class entities & the edge graph: every record a golden record, visibility derived

*Validated in brainstorm, 2026-06-12.*

## Decisions

1. **Every entity is its own golden record.** Products, substances, descriptions, media —
   and later brands/organisations — each get the full machinery: clustered identity,
   attributes, survivorship, merge/split, bitemporal history, steward gating. Nothing is a
   string tag or an attachment-only satellite.
2. **Typed entity lanes.** The scheme registry declares an `entity_type` per code scheme
   (`gtin`/`cnk` → product, `cas`/`atc` → substance, …). Identity claims route to their
   lane; each lane folds its own ledger with its own surrogate keys and steward queue.
   Cross-type bridging is structurally impossible — disjoint folds, not a validation rule.
3. **Identity for born-in-engine records: minted UUID.** A description or asset arriving
   from a source carries the source's ID as an identity code; one created without a source
   ID gets an engine-minted `{:uuid, …}` code. `uuid` is a shared scheme usable by any lane.
4. **Relationships are edge claims, both endpoints codes.** A generalized `:edge` claim
   (`from`, `relation`, `to`) replaces ad-hoc kinds. Endpoints are canonicalized codes
   resolved to current surrogate keys **at read time** via each lane's `resolve_key` — the
   single decision that makes every edge survive merge/split on either side for free.
5. **Edge home: the asserting entity's stream.** "Product contains X" routes by the
   product (`from`) endpoint's lane and re-homes on the product's split. No global edge
   log — it would lose per-type re-homing.
6. **Visibility is a derived projection, never a stored link.** The product page computes
   descriptions by traversing the edge graph at read time. "Product C newly claims
   substance A ⇒ A's descriptions appear on C" falls out of the fold; nothing is copied.
7. **Relation-scoped propagation, not transitive closure.** Traversal rules are named,
   per-relation, depth-bounded config in the scheme registry. Blanket reachability would
   over-share (a common excipient dragging its descriptions onto thousands of products).
8. **Union across sources + steward suppress.** Edges union (any live source ⇒ edge holds).
   A steward hides one derived pairing with a negative `suppress` edge scoped to that
   product, leaving the substance tag intact. Suppress and split ride the existing
   four-eyes gate.
9. **Traversal provenance on the page.** Every derived item carries its path —
   "shown because C contains substance A, asserted by medipim" — making over-sharing
   reviewable.

## 1. Typed entity lanes

Registry change: each scheme declares `entity_type`. Identity claims mixing schemes from
two lanes are a contract validation error, rejected at `POST /claims` before reaching the
log. `Cluster`, `IdentityLedger`, `Stewardship`, `Survivorship` are already type-agnostic
folds — they run once per lane over disjoint claim streams, unchanged internally. Surrogate
keys become lane-qualified (`{:product, k}`, `{:substance, k}`). Existing data migrates as
the `:product` lane. A substance name disputed by two sources is an ordinary attribute
conflict in the substance lane — same queue, same rules.

## 2. Edge claims

```json
{ "kind": "edge", "source": "medipim",
  "from": "cnk:0422156", "relation": "contains", "to": "cas:50-78-2",
  "valid_from": "2024-03-01" }
```

Slot identity `{source, :edge, from, relation, to}` — idempotent resubmission, independent
provenance per source on one logical edge. Relations are declared in the scheme registry
with type signatures (`contains: product → substance`, `describes: description → product |
substance`, `depicts: media → product | substance`); mismatched endpoints are contract
errors. New relations are config, not engine changes (the M3 genericity rule, extended to
relationships). Edges are claims, so they are retractable (latest-wins), bitemporal, and
visible in history.

Migrations: `:member_of` becomes an edge relation; `:media` claims become media-lane
identity + attributes + a `depicts` edge.

## 3. The visibility projection

```
descriptions_on(P) =
  let S = { resolve_key(substance, c) : edge(P —contains→ c) }
  in  ⋃ { D : s ∈ S, edge(D —describes→ s) }   minus suppressed, each with its path
```

`Catalog.project` gains a `resolve_descriptions` shaped like `resolve_categories`: filter
edges by relation, resolve both hops code→key at read time, union, group by routing
substance, attach `via` + `asserted_by`, drop steward-suppressed pairings. Merge two
substance records and every description tag and product link converges; split one and the
steward-gated split decides which part keeps each edge — the structural safety valve
against a description leaking onto the wrong products.

## Out of scope (YAGNI)

Arbitrary-depth graph queries, a generic graph query language, ML-suggested edges,
cross-lane survivorship. Brand/organisation lanes are enabled by the design but not built
until a source supplies them.

## Build order

1. Registry: `entity_type` per scheme + relation declarations with signatures and
   traversal rules (contract package, MIT).
2. Edge claim kind in the engine: normalization, slot, validation against signatures;
   `member_of` migrated to a relation.
3. Per-lane folds: route identity claims, lane-qualified keys, per-lane steward queues;
   existing data as `:product` lane; UUID minting.
4. Substance + description + media lanes exercised end-to-end (medipim adapter emits
   substance/description claims + edges).
5. `resolve_descriptions` traversal projection with provenance, grouped by substance.
6. Steward suppress edge + four-eyes; surfaced in queue and API.
7. Contract schemas + docs updated (`claims.schema.json`, HISTORY_ENVELOPE notes).
