# Story demo — a guided presentation of the new way of working

**Status:** designed 2026-06-10 (brainstorm). Builds on the temporal-pass viz (`gr-nyf`/`gr-4ec`,
branch `temporal-viz`). Audience: decision-makers **and** engineers, in one sitting.

## Problem

The viz app shows two isolated scenes (the as-of time machine, the over-merge guard), and the
`.exs` explainers tell the rest in terminal text. Neither *presents*: there is no single
narrative an audience can follow from "why the old way fails" to "why a mistake is cheap here."
To pitch the new way of working we need a rehearsable, story-driven demo where every step shows
a real state change — visual enough for decision-makers, engine-faithful enough for engineers.

## Goal (this increment)

A **guided story mode** in `viz/`: six chapters in fixed order, each broken into steps advanced
by arrow keys/click, every step animating real engine state with a one-line on-screen caption.

Non-goals: no live editing, no backend, no free-form exploration mode (the standalone scenes
remain for that). The viz stays presentational — it reimplements none of the engine.

## The narrative arc

| # | Chapter | Status | The beat |
|---|---------|--------|----------|
| 1 | **The old way** | new | Two source records destructively merged: fields overwrite, provenance evaporates; a later import builds on the fused record. "The mistake is now permanent — and invisible." Deliberately the strawman chapter 6 answers. |
| 2 | **Claims, not records** | new | Sources assert code-anchored claims ("source 1034 says GTIN …004 weighs 250 g"); claims stream into an immutable log; a golden record *materializes* as a fold — visibly derived, never stored. |
| 3 | **Who wins?** | new | Three sources disagree on one field; per-dimension priority tiers rank them; winner shown with full provenance. Then a top-tier tie → the field flags to the steward queue instead of guessing. |
| 4 | **Identity has a "when"** | embed | The existing time machine (real 422156), as a chapter. |
| 5 | **The guard** | embed | The existing over-merge scene: late bridge code → flagged proposal, never auto-merge. |
| 6 | **The mistake is cheap** | new | A steward approves a merge that turns out wrong → contradicting weight claims surface a conflict *because evidence was never destroyed* → steward splits → every attribute/media claim re-homes automatically. "Nothing re-imported, nothing lost." |

## Decisions (settled in brainstorm)

| Fork | Decision | Why |
|------|----------|-----|
| Format | Extend `viz/` (Astro + motion) | Visual for decision-makers; engine-exported data for engineers; one reusable artifact. |
| Flow | **Guided story mode** | Fixed chapter/step order, rehearsable, hard to get lost mid-talk. Number keys jump to a chapter for Q&A. |
| Data | **Real engine, synthetic input** | New scenes' scenarios are hand-crafted *claims* pushed through the actual engine; the viz replays exported snapshots. Same seam the time machine proved. |
| Old-way data | Hand-authored, labeled "legacy behaviour (illustration)" | Destructive merging is what our engine refuses to do; it cannot be engine-exported. Visual labeling protects the credibility of the faithful chapters. |
| Export file | New `viz/src/data/story.json` via new root `demo_export.exs` | `temporal.json` / `temporal_export.exs` untouched — zero risk to working scenes. |
| Engine change | Add `Stewardship.split/…` | `IdentitySplit` exists as an event and reconcile emits it for natural splits, but there is no steward-*initiated* split mirroring `approve_merge`. Chapter 6's claim is precisely "split is a recorded engine operation," so this is a genuine engine addition, not demo scaffolding. |
| Routing | Story at `/`; standalone scenes move to `/machine` + `/guard` | The story is the front door; the scenes stay reachable for Q&A. |

## Architecture — the proven one-way seam, extended

```
demo_export.exs ──drives the REAL engine through the story──▶ viz/src/data/story.json
   (Elixir, stdlib JSON)                                          (committed, regenerable)
                                                                        │
                                                          Story island replays it, step by step
```

`demo_export.exs` builds the synthetic scenarios for chapters 2, 3, 6 as claims, then drives
`Substrate` / `Cluster` / `IdentityLedger` / `Survivorship` / `Stewardship.approve_merge` /
`Stewardship.split` / projection, capturing a **named snapshot after each beat**: the claims
visible so far, the events emitted, the projected golden record(s). A viz step swaps which
snapshot is displayed; `motion` animates the diff. The viz computes nothing.

### Viz components

- `Story.tsx` — the one new island. Owns `{chapter, step}`; `→`/`←` + click zones advance;
  thin progress rail (chapters as dots); number keys jump chapters. Step derivation is a pure
  `stepState(story, chapter, step)` in `src/lib/`, vitest-tested like `snap.ts`.
- `src/components/chapters/OldWay.tsx`, `ClaimsIntro.tsx`, `PriorityDuel.tsx`, `MistakeArc.tsx`
  — new chapters rendering `story.json` snapshots.
- Chapters 4/5 **reuse** `TimeMachine.tsx` / `OverMergeGuard.tsx` via a new `embedded` prop
  (hide standalone headers, signal chapter-complete); standalone routes stay unchanged.
- `narration.ts` — one-line caption per `(chapter, step)`, on-screen (the demo also works
  self-driven as a shared link).

**Visual continuity carries the argument:** the same claim-card and golden-card language across
chapters, so the chapter-6 golden record is recognizably the same fold the audience watched
materialize in chapter 2. The old-way chapter gets a deliberately duller treatment (flat gray
cards, no provenance chips) — the visual *absence* of provenance is the point.

## Testing — two layers matching the seam

- **ExUnit** `test/demo_export_test.exs`: runs the story scenario through the engine and asserts
  each beat — claims cluster as scripted, `approve_merge` fuses, the weight contradiction flags
  after the merge, the split re-partitions, post-split projections show every attribute/media
  claim re-homed. Plus a test for `Stewardship.split`. **This is the "demo can't lie" guarantee.**
- **vitest**: `stepState` navigation (bounds, jumps), plus a schema check that the committed
  `story.json` matches what the components expect.

## Build plan — four streams

1. **Engine + export** (Elixir): `Stewardship.split` → `demo_export.exs` (three scenarios) →
   ExUnit suite → commit generated `story.json`.
2. **Story shell** (viz): `Story.tsx`, navigation, rail, narration map, routing — buildable
   against a hand-stubbed `story.json`, swap in the real export when stream 1 lands.
3. **New chapters** (viz): the four chapter components — depends on the shell's chapter contract.
4. **Embed refactor** (viz): `embedded` prop on the two existing scenes; standalone routes green.

Streams 1 and 2 start in parallel; 3 and 4 follow the shell. Final integration: real
`story.json` in, full click-through rehearsal, `mix test` + vitest green.
