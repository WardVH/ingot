# Temporal pass — identity timeline + bitemporal golden as-of

**Status:** designed 2026-06-09 (brainstorm). Epic `gr-cdy` (legacy-medipim ingest) closed PoC-complete;
this is the first post-PoC follow-up, the "Temporal pass (follow-up, not v1)" promised in
`docs/plans/2026-06-05-legacy-history-ingest-design.md`.

## Problem

v1 folds each legacy listing to its **final** code-set — a snapshot. `GoldenRecords` projects via
`Catalog.project` (Date-free, recency by integer `order`) precisely because envelope timestamps are
integer Unix epochs, not `Date`s. A snapshot answers *"what is this product now?"* but throws away
*when* identity changed.

The motivating real case is entity **422156**: all three source orgs (1034, 1035, 44) end up on CNK
`3612173` + GTIN `03282770146004`, but **not at the same time**. Org 44 began divergent (a different
EAN, no CNK) and only converged (EAN in 2023-08, CNK in 2024-03). A snapshot says *"legacy was right,
one clean product."* The temporal pass recovers that it only **became** one — org 44 was a distinct
identity for years.

## Goal (this increment)

Two deliverables, both **as-of-date**:

1. **Identity timeline** — the ordered mint/merge/split history with real dates (*when* identity changed).
2. **Bitemporal golden time-travel** — project the full golden record as it was known on any past date.

Reuse the engine's proven temporal machinery; **the same envelope feeds both folds — only the fold
changes.**

## Decisions (settled in brainstorm)

| Fork | Decision | Why |
|------|----------|-----|
| Scope | Timeline **+** golden as-of-date | The design doc's stated goal, plus the time-travel the snapshot can't do. |
| Epoch→Date | **Convert at the ingest boundary** | Reuse the engine's tested `project_bitemporal` **unchanged**; keep `golden_record_core.ex` Date-pure (zero blast radius on existing demos/tests). |
| Re-cluster | **Fold-forward**, threading the prior ledger | Keeps surrogate keys *stable* across time; snapshot-then-diff would reshuffle keys and make the timeline unreadable. Idiomatic — it's what `golden_record_ddd.exs` already does across hand-picked dates. |
| Event vocabulary | The engine's existing events | `IdentityMinted` / `IdentityMembersChanged` / `IdentitiesMerged` / `IdentitySplit` — no new types. |
| Temporal reach | **Golden + timeline only** | `LegacyXref` / `MigrationDiff` stay snapshot/final-state — their job is "where does legacy land *now* for cutover." Temporalizing them is YAGNI here. |

## Architecture — purely additive

Nothing in the engine or the v1 ingest changes. The temporal pass is a **second fold** over the same
claims `ClaimMapping.build/1` already produces.

| Artifact | Role |
|----------|------|
| `lib/ingest/temporal.ex` (`Temporal`) | Boundary epoch→`Date` conversion, fold-forward reconciliation emitting *dated* identity events, the temporal log, and `timeline` / `golden_as_of`. |
| `temporal_ingest.exs` (root demo) | Runnable PoC (`mix run`): 422156 timeline + golden-as-of before/after convergence. |
| `test/ingest/temporal_test.exs` | ExUnit: dated timeline events, before/after variant counts, the temporal-converges-to-snapshot guard. |

## Data flow & algorithm

**Step 1 — Boundary conversion.** `Temporal.run(envelopes)` → `ClaimMapping.build/1` → `%{claims, shared}`.
Map each claim's integer-epoch `recorded_at`/`valid_from` once: `DateTime.from_unix!(epoch) |> DateTime.to_date()`.
Keep `valid_from = recorded_at` (legacy deltas carry one clock → uni-temporal). Preserve integer `order`
for within-day sequencing. **v1's `Rederivation` is untouched** — `Temporal` works on its own Date-stamped copy.

**Step 2 — Fold-forward reconcile.** Sorted distinct `Date`s from the claims. From `IdentityLedger.new()`,
for each date `d`:

```
live_d    = claims |> Enum.filter(&(Date.compare(&1.recorded_at, d) != :gt)) |> Substrate.current()
clusters_d = Cluster.variants(live_d, shared)
events_d   = IdentityLedger.decide(ledger_prev, {:reconcile, clusters_d, shared, d})   # stamped recorded_at: d
ledger_d   = Enum.reduce(events_d, ledger_prev, &IdentityLedger.evolve(&2, &1))
```

Threading `ledger_prev` is what keeps surrogate keys stable. `decide` emits exactly the mint/merge/split/
members-changed events to evolve the prior ledger into `d`'s clustering.

**Step 3 — Temporal log.** `temporal_log = date_stamped_claims ++ all_dated_identity_events`, re-`order`-stamped
monotonic (mirroring v1's `stamp/2`). Fully `Date`-typed → the engine reads it unchanged.

**Step 4 — Outputs.**
- `timeline` = the dated identity events, sorted by `(date, order)`.
- `golden_as_of(temporal_log, date)` = `History.project_as_of(temporal_log, date, priority)` — golden as known on `date`, for free.

## The PoC artifact (`temporal_ingest.exs`)

Mirrors `golden_record_ddd.exs`'s style. Loads real 422156 and prints:

- **Block A — Identity timeline:** dated `MINT/MEMBERS/MERGE/SPLIT` lines (exact keys/dates computed from
  the fixture, not hard-coded).
- **Block B — Golden as-of, before vs after:** `golden_as_of` at one date pre-convergence (2 variants —
  org 44 separate) and one post (1 variant — merged).
- **Block C — Small as-of grid:** variant-count per as-of date across a handful of dates (the "it *became*
  one" arc), reusing the grid idea from `golden_record_ddd.exs`.

Punchline the demo states outright: *a snapshot says "one clean product"; the temporal pass recovers that
it only became one.*

## Testing (`test/ingest/temporal_test.exs`)

> **T2 finding — the honest behaviour is narrower than this design first imagined.** Two structural
> facts, established empirically while writing the tests, reshape what the suite can assert:
>
> 1. **`ClaimMapping` folds each source-listing's identity to a *single* final-code-set claim** (stamped
>    at that listing's latest identity date). The temporal pass folds over already-folded claims, so it
>    recovers *when each listing's identity was first recorded*, **not** the intra-listing EAN evolution.
>    For 422156 every listing already carries the convergent CNK + GTIN, so the timeline is a **single
>    dated mint** — the "org 44 diverges for years then merges in" arc is folded away *before* the
>    temporal pass ever runs. The datable transition is **0 → 1 variant** (a mint), not 2 → 1 (a merge).
> 2. **The reconcile never auto-emits `IdentitiesMerged`.** When a later code bridges two *established*
>    keys, the gr-ose over-merge guard **gates** it into a `ConflictFlagged` proposal; auto-merge happens
>    only via `Stewardship.approve_merge`. So a "two-keys-then-merge" case yields a *flagged proposal*,
>    not an auto-merge — the guard holds temporally too.
>
> The suite below asserts that honest behaviour. (The "watch org 44 merge in" narrative would require
> folding over finer-grained-than-listing identity — out of scope here; filed as a follow-up if wanted.)

1. **Real 422156 — datable identity.** Derive the mint date in the test (don't hard-code prose):
   - timeline is a **single dated `IdentityMinted`** for `SK_1`, in the 2023–2024 window, carrying canonical
     CNK `3612173` + GTIN `03282770146004`;
   - `golden_as_of(before the mint)` → **0 variants** for product 422156; `golden_as_of(on/after)` → **1 variant**
     carrying those canonical codes;
   - **Monotonicity guard:** `golden_as_of` at the latest known date **equals the v1 snapshot**
     (`GoldenRecords.from_envelopes`, `:cnk` enrichment stripped) — the temporal fold must converge to the
     already-trusted end state. The core correctness anchor.
2. **Synthetic over-merge guard, temporally.** Three listings on one entity: `C={gtin}` and `D={cnk}` (disjoint)
   at d1; `E={gtin,cnk}` bridges them at d2. Assert: at d1 → **2 keys** (`SK_1`,`SK_2`); at d2 → a dated
   **`ConflictFlagged{:merge,[SK_1,SK_2]}`** and **still 2 keys** — no `IdentitiesMerged` anywhere.
3. **Synthetic `MembersChanged`.** A later listing's *new* code extends the existing key: assert a dated
   `IdentityMembersChanged` and that the variant lacks the code before / carries it after (same key throughout).
4. **Boundary conversion.** A known epoch converts to the expected `Date` (`valid_from == recorded_at`); same-day
   deltas collapse to one date but stay `order`-sequenced, and survivorship picks the later-order (end-of-day) value.

Gate: `mix test` (all suites stay green — additive), `mix format --check-formatted`, `mix run temporal_ingest.exs` clean.

## Edge cases & known simplifications (documented in the moduledoc)

- **Day granularity — does NOT corrupt values.** Epoch→`Date` collapses sub-day deltas onto one temporal point.
  Two updates on the same day both stay in the log (distinct `order`); projecting as-of that day includes both
  (filter is `recorded_at <= D`) and the survivorship winner is chosen by `Enum.max_by(.., & &1.order)` —
  **integer `order`, not the Date** (`golden_record_core.ex` lines 181/210). So same-day updates resolve to the
  correct **end-of-day** value; the later one wins any shared field. What's lost is only the ability to
  *time-travel to the intra-day midpoint* (`as_of(D-1)` = before both, `as_of(D)` = after both; nothing addresses
  between). Because resolution keys off `order` not Date, collapsing to days **cannot change any resolved value** —
  which is also why the monotonicity guard holds (v1's `Catalog.project` uses the same `order`-based recency).
- **Uni-temporal.** `valid_from = recorded_at` (one clock) → `project_as_of`, not a true two-axis grid. Honest to
  the data; the engine's full bitemporal API stays available if a second clock ever appears.
- **`shared` computed once** from the full history, not per-date — globally correct, avoids an early reconcile
  mis-bridging a code before its reuse is visible.
- **Op-4 deletes / set-null cleanups.** When a bridging code is *removed*, the fold-forward naturally emits a late
  members-change/split — the timeline shows divergence too, not only convergence. The demo won't choke on the
  fixture's 2026 set-null cleanups.
- **Media churn (≈82% of events)** is already dropped upstream by `ClaimMapping`; the temporal fold inherits that.
- **Priority** stays the permissive v1 default (`Priority.new(%{}, [])`); per-as-of-date attribute conflicts surface
  as `needs_review`, never silently picked.

## Build order

| Bead | Scope | Deps |
|------|-------|------|
| **T1** `lib/ingest/temporal.ex` | Boundary conversion + fold-forward reconcile + temporal log + `timeline` / `golden_as_of` | — |
| **T2** `test/ingest/temporal_test.exs` | The 3-part test plan incl. monotonicity guard | T1 |
| **T3** `temporal_ingest.exs` demo | Timeline + before/after golden + punchline | T1 |

T2 and T3 depend only on T1 and touch disjoint files → parallel-dispatchable once T1 lands.
