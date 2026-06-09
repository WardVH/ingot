# Temporal-pass visualization — an Astro + motion "as-of time machine"

**Status:** designed 2026-06-09 (brainstorm). A presentation layer over the temporal pass
(epic `gr-nh0`, closed: T1 module `gr-a2j` #17, T2 tests `gr-qka` #18, T3 demo `gr-aqb` #19).
Lets you *watch* what `temporal_ingest.exs` prints — drag a date and see the golden record
materialize, and see the over-merge guard flag a bridge instead of merging.

## Problem

`temporal_ingest.exs` tells the temporal story in text: a single dated mint, a 0→1 as-of
transition, and the synthetic over-merge guard. Text is honest but flat — you read *that* identity
became resolvable on 2023-11-15; you don't *feel* the 0→1 step. A visual, interactive scrubber makes
the temporal behaviour tangible: drag left and the product **un-becomes** identified.

## Goal (this increment)

An interactive **as-of time machine** in the browser, with two scenes:

1. **422156 time machine** — a draggable date axis (2018→2026); the golden-record card materializes
   at the mint date, claims light up as they become known.
2. **Over-merge guard (synthetic)** — two established keys; a late barcode bridges them; the engine
   **flags** a merge proposal rather than silently merging — both keys survive.

Non-goals: no live editing, no backend, no general bitemporal grid (the `.exs`/engine cover that).
The viz is **presentational** — it reimplements none of the engine.

## Decisions (settled in brainstorm)

| Fork | Decision | Why |
|------|----------|-----|
| Experience | **Interactive as-of scrubber** (not auto-play) | "See what happens while it happens" → the user drives the date; the 0→1 step is felt, not narrated. |
| Data boundary | **Precomputed JSON export** from the real Elixir engine | Browser can't run Elixir; the as-of projection only changes on distinct claim dates, so it fully precomputes. Faithful, no runtime Elixir, no duplicated fold logic. |
| Scope | **Both scenes** (time machine + over-merge guard) | Both halves of the punchline; the synthetic data is already in the export — modest extra build. |
| Project home | **`viz/` subdirectory, own `package.json`** | Keeps the Mix repo dependency-free; the web app is a committed sibling, not a Mix dep. |
| Stack | **Astro + one React island + `motion` (motion.dev)** | Static site, a single interactive island for the scrubber; `motion/react` (ex-Framer Motion) for drag + `AnimatePresence`. |
| Commit policy | **Commit the whole `viz/` source + `temporal.json`**; gitignore only `node_modules/` + `dist/` | Clone-and-run reproducibility; `package-lock.json` pins versions; the data file is committed *and* regenerable. |

## Architecture — a one-way data seam

Nothing in the engine or v1/temporal ingest changes. The viz reads a snapshot the engine produces.

```
temporal_export.exs  ──run the REAL Temporal engine──▶  viz/src/data/temporal.json
   (Elixir, stdlib JSON)                                   (committed, faithful)
                                                                    │
                                                          Astro/React reads it
                                                          scrub → asOf[lastDate ≤ cursor]
```

| Artifact | Role |
|----------|------|
| `temporal_export.exs` (root) | Runs `Temporal.run/1` on the real fixture + the synthetic guard; serializes to `viz/src/data/temporal.json` via the stdlib `JSON` module. **Generated — do not hand-edit.** |
| `viz/` (Astro project) | Static site; one React island per scene, animated with `motion`. |
| `viz/src/data/temporal.json` | The committed, regenerable data snapshot (the only engine→browser bridge). |

**Faithful vs presentational.** Faithful (from the engine): every claim date, timeline event, as-of
variant/code/attribute. Presentational (in the viz): layout, motion, colour, the scrubber. Change
the fixture or engine → re-export → the viz updates; no hand-edited data.

## The JSON export contract

`temporal_export.exs` writes one object per scene. Codes (Elixir tuples `{:cnk, "3612173"}`)
serialize as `"cnk:3612173"` strings — the form the `.exs` demo already prints.

```jsonc
{
  "real": {
    "label": "medipim entity 422156",
    "dates": ["2018-08-31", ...],          // every distinct claim date, sorted
    "mintDate": "2023-11-15",              // derived — the "first identified" marker
    "claims": [
      { "date": "2023-11-15", "kind": "identity", "source": "1035",
        "codes": ["cnk:3612173", "gtin:03282770146004", ...] }, ...
    ],
    "timeline": [
      { "date": "2023-11-15", "type": "MINT", "key": "SK_1", "codes": ["cnk:3612173", ...] }
    ],
    "asOf": {                              // golden_as_of at EACH distinct date
      "2023-11-14": { "variants": [] },
      "2023-11-15": { "variants": [
        { "key": "SK_1", "product": 422156, "cnk": "cnk:3612173",
          "codes": ["cnk:3612173", ...],
          "attributes": [ {"field": "name:fr", "value": "...", "status": "resolved"},
                          {"field": "status", "value": "active", "status": "resolved"} ] } ] },
      ...
    }
  },
  "synthetic": {                           // the 3-listing over-merge guard
    "label": "over-merge guard",
    "steps": ["2024-01-01", "2024-06-01"],
    "timeline": [ {"date":"2024-01-01","type":"MINT","key":"SK_1","codes":["cnk:1000000"]},
                  {"date":"2024-01-01","type":"MINT","key":"SK_2","codes":["gtin:05000000000017"]},
                  {"date":"2024-06-01","type":"FLAG","subject":["SK_1","SK_2"]} ],
    "asOf": { "2024-01-01": {"variants":[{key:"SK_1",...},{key:"SK_2",...}]},
              "2024-06-01": {"variants":[{key:"SK_1",...},{key:"SK_2",...}]} }   // still 2 — gated
  }
}
```

Runtime logic in the browser is one line: `asOf[lastDateAtOrBefore(cursor)]`.

## Scene 1 — the 422156 time machine

**Layout.** A horizontal time axis (2018→2026), a tick per distinct claim date, a labelled **MINT**
flag at the mint date, a draggable cursor, the golden-record card below, and a readout
(`as-of 2024-03-14 · 1 variant`).

**Interaction.** Cursor is a `motion.div` with `drag="x"` constrained to the axis; a `useMotionValue`
maps x → nearest tick **at or before** the cursor (`lastDateAtOrBefore`), which keys into `asOf`.
Keyboard ←/→ step tick-to-tick; clicking a tick jumps.

**Motion — "while it happens".**
- Claim markers brighten and pulse once as the cursor passes their date — knowledge accumulates L→R.
- Crossing the mint date, the card animates in (`AnimatePresence`, scale + fade up from the MINT
  flag); before it, a ghost placeholder ("no resolvable identity yet").
- Code chips stagger in; the CNK chip is highlighted canonical. A couple of resolved attributes
  (`name:fr`, `status`) render so the card reads as a real golden record. `layout` keeps reflow smooth.
- Scrubbing backward reverses everything — the card dissolves back to the ghost before the mint.

## Scene 2 — the over-merge guard (synthetic)

A two-stop `d1 → d2` stepper (only two dates matter).
- **d1:** two cards apart — `SK_1 [cnk]`, `SK_2 [gtin]`.
- **d2:** a bridge node `E [cnk, gtin]` slides in between; an edge draws (`pathLength`) linking the
  keys; then a ⚠ **FLAG: merge proposal (gated)** badge springs onto the edge, and the cards
  pull-together-then-recoil. Caption: *"a late barcode bridges two established identities → the guard
  flags a proposal; both keys survive — no silent merge."*

It rhymes with Scene 1's restraint: the engine refuses to over-claim.

## Build, run, testing

- **Run:** `cd viz && npm install && npm run dev`. **Build:** `npm run build`.
- **Regenerate data:** `mix run temporal_export.exs` (documented in `viz/README.md`).
- **Testing (lean — presentation layer):** one Vitest unit test on the only real logic,
  `lastDateAtOrBefore(cursor)`. Gates: `npm run build` succeeds and `mix run temporal_export.exs`
  runs clean. No heavy E2E (YAGNI).
- **Commit:** all of `viz/` source + `temporal.json`; gitignore `viz/node_modules/` + `viz/dist/`.

## Build order

| Bead | Scope | Deps |
|------|-------|------|
| **V1** | `temporal_export.exs` + JSON contract → `viz/src/data/temporal.json` | — |
| **V2** | Astro/React/`motion` scaffold + app shell (tabs, `lastDateAtOrBefore` util + Vitest test, styling, README, gitignore) | — |
| **V3** | Scene 1 — 422156 time machine (scrubber + card + motion) | V1, V2 |
| **V4** | Scene 2 — over-merge guard (stepper + bridge + FLAG) | V1, V2 |

V3 and V4 touch disjoint scene files over the shared data + shell → parallel-dispatchable once V1+V2 land.
