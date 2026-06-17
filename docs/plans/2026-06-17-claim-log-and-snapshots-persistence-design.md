# Claim log & snapshot persistence: medipim hosts the golden record (shadow phase)

*Validated in brainstorm + implemented as the shadow phase, 2026-06-17.*

How `ingot/ingot` is persisted and driven **inside medipimv2, next to the existing
deltas**. The package owns the contract and the reconcile engine; medipim owns the storage and the
write/read seams. This is the consumer-integration counterpart to the engine epic **gr-l6v** (Engine
replaces `products_deltas`); it lands phases P0–P4 in *shadow* (writes mirrored, nothing cut over).

## Decisions

1. **The package defines ports; the consumer provides the adapter.** Storage is a single interface,
   `Ingot\Storage\ClaimStore`, plus a DDL helper `Ingot\Storage\Schema`. medipim
   implements `DbalClaimStore` over its existing `DbalConnection`; a Doctrine migration runs
   `Schema::statements('claim_')`. The shape lives in one place (the package), the SQL in one place
   (the adapter). The in-memory `InMemoryClaimStore` is the executable spec the DBAL twin matches.
2. **Append-only event log + per-key incremental snapshots — never a global snapshot.** Six tables
   (`claim_events`, `claim_snapshots`, `claim_members`, `claim_redirects`, `claim_lane_seq`,
   `claim_backfill_seen`). The event log is the system of record; every projection is a fold. Each
   write loads ONLY the keys whose codes the batch touches, so the model scales to live per-write
   ingest. (P0 / gr-h4k.)
3. **Single claim writer, enforced by a MySQL named lock.** `DbalClaimStore::transactionally`
   takes `GET_LOCK('claim_writer')` and wraps the batch in one transaction — the engine's reconcile
   is not safe to interleave. The lock is released on the same connection in a `finally`.
4. **Two ingest paths, one reconcile pipeline.** `ClaimIngest::backfill` replays full delta history
   (idempotent per entity via a content fingerprint in `claim_backfill_seen`); `ClaimIngest::live`
   takes current-truth envelopes (idempotent per slot). One decoder serves both and every lane.
5. **The live shadow is a secondary projection, exactly like the Elasticsearch reindex.** It runs
   **after** the delta is durably committed (never inside the delta transaction), in its own
   transaction, fully guarded (failures logged, never thrown) and behind a feature flag
   (`INGOT_SHADOW_ENABLED`, off by default). This mirrors `MysqlEsProductRepository`'s
   `reindexInElasticsearch` self-healing pattern — the established medipim shape for derived state.
6. **The repository is the seam, not the writer.** The three `MysqlEs*Repository::save()` methods
   already reload the resulting snapshot for the ES projection (or can, for products). Hooking there
   gives uniform, post-commit access to the resulting `Snapshot` for all three lanes and reuses the
   already-loaded snapshot for descriptions/media. The hook is a *nullable* constructor arg so the
   repositories' unit tests (the only `new` sites) keep compiling.
7. **Products, descriptions and media are first-class lanes.** Products carry natural identity codes
   (cnk/ean/…). Descriptions and media carry none in their own deltas, so the decoder injects a
   synthetic lane identity (`text_id` / `asset_id`) keyed by the medipim entity id, minting a
   `DSC_`/`MED_` lane record. Product `media`/`descriptions` collections become `depicts`/`describes`
   edges back to the product anchor.
8. **One snapshot→claims flattening, shared by live and parity.** `SnapshotClaimMapper` turns any
   medipim `Snapshot` into the package's lane-agnostic `perSource` shape using each field's meta
   (sourced / localized / multi / collection). It is deliberately dumb — the decoder decides
   identity vs attribute vs edge in ONE place — and best-effort (structured values like Weight are
   skipped, surfaced by parity rather than guessed).
9. **Parity-first rollout.** A read-only harness (`ingot:parity`) diffs the engine
   projection of an entity against medipim's own snapshot of it (both derive from the same deltas).
   It exercises *both* shadow paths — the backfill decoder and the live mapper — and reports
   attribute + identity-code differences. Divergences are closed (or explained) before any cutover.

## The store tables (owned by `Schema`)

| table | role |
|---|---|
| `claim_events` | append-only `ClaimAsserted`/identity event log — the system of record |
| `claim_snapshots` | per-key materialized view (codes, current claims, `last_seq`); rebuildable |
| `claim_members` | code → surrogate-key resolution index (the ledger) |
| `claim_redirects` | old-key → new-key after a merge (cycle-guarded follow) |
| `claim_lane_seq` | per-lane mint counter for surrogate keys (`SK_`/`DSC_`/`MED_`) |
| `claim_backfill_seen` | `(legacy_entity, fingerprint)` for backfill idempotency |

## medipim components (`Baldpim\Domain\Ingot\`)

- **`Infrastructure\DbalClaimStore`** — the `ClaimStore` adapter (single-writer lock, JSON columns,
  epoch coercion, redirect-follow). Wired to the port via a `services.yml` alias.
- **`Infrastructure\SnapshotClaimMapper`** — `Snapshot` → `perSource` (pure, meta-driven).
- **`Application\ClaimShadowWriter`** — guarded, flag-gated live bridge: `Snapshot` → envelope
  (`SnapshotTranslator`) → `ClaimIngest::live`. Hooked into product/description/media
  `MysqlEs*Repository::save()` post-commit.
- **`Application\ClaimParity`** — pure comparator: engine claims vs `perSource` → attribute &
  identity-code diff.
- **`Console\BackfillClaimsCommand`** (`ingot:backfill-claims {product|description|media|all}`)
  — keyset-paginates each `*_deltas` table, decodes each entity's history (preserving historical
  `created_at` as `recorded_at`), folds via `ClaimIngest::backfill` in batched transactions.
- **`Console\ParityCommand`** (`ingot:parity {lane} {entity}`) — the parity harness.
- **`migrations/Version20260617120000`** — creates the six tables via `Schema::statements()`.

## Rollout phases (and their beads)

| phase | what | bead |
|---|---|---|
| P0 | persisted ledger/catalog state (store + adapter + migration) | gr-h4k |
| P1 | claim-mapping spec / delta→claim translator | gr-thr |
| shadow | live shadow ingest wired, flag off → on per env | *gr-h4k / this doc* |
| backfill | run `backfill-claims` at scale, verify counts | gr-afy (P4) |
| P2/P3 | parity harness at scale, close gaps to zero-or-explained | gr-yfh, gr-be3, gr-536 |
| P5/P6 | cutover reads, then writes; retire delta machinery | gr-xhd, gr-aw5 |

## Validation done now (no live DB)

- Decode→backfill on the committed real fixtures: BE `422156` 1676 deltas → 118 claims, `cnk` →
  `SK_1`, idempotent re-run; FR `347025` likewise. (Mirrors `BackfillClaimsCommand` exactly.)
- `ClaimParity` end-to-end on real engine output: an aligned snapshot matches; a drifted one
  surfaces the mismatch + engine-only + medipim-only rows.
- Package suite green; all new medipim PHP lints clean; `services.yml` parses.

## Out of scope (YAGNI for the shadow phase)

Reads from the engine, lookup-adapter cutover, retiring `*_deltas` (P5/P6 — gr-xhd/gr-aw5). Leaflets
and other lanes (the decoder already serves them; wire when a parity need appears). Async/queued
shadow ingest (the guarded inline reload behind the flag is enough until parity says otherwise).
