# Data-driven product-code registry — all medipim national + GTIN codes

**Date:** 2026-06-08
**Status:** Validated design, ready for implementation
**Repos:** `brainstorming-experiments` (this engine, Elixir) · `baldwin/medipimv2` (legacy source, PHP)
**Follows:** `2026-06-05-legacy-history-ingest-design.md` (the ingest pipeline this extends)

## Goal

The ingest must recognise **every** product identity code medipim carries — not just the Belgian
`cnk`/GTIN set the PoC started with. The trigger was a real French extract (entity `347025`, codes
`cipOrAcl7` + `acl13`, no CNK), but France is one of ~9 markets. Rather than patch schemes
country-by-country, drive scheme handling from **one registry** sourced from medipim's own value
objects, so adding a market later is a data change, not a code change.

The authoritative roster was extracted from `medipimv2/src/Baldpim/Domain/Product/Value/*.php`
(classes implementing `ProductIdentifierInterface`) plus `ProductMetaFieldBuilder` /
`ProductCodeFactory` / `PrimaryProductCodeDeterminationFlow` / the GTIN expander.

## The roster (from medipim)

**identity-bridge — national codes** (each its own scheme; many zero-pad to a fixed width):
`cnk` (BE, pad7) · `cip_acl7` (FR/LU, pad7) · `acl13` (FR/LU, 13, `^3401…`) · `cip13` (FR/LU, 13, `^3400…`)
· `pzn` (DE, pad8) · `pznAustria` (AT, pad7) · `sukl` (CZ, pad7) · `pdk` (CZ) · `cn`/CodeNational (ES/LU, 6)
· `cefip` (LU, pad7) · `nationalCode` (LU, pad7) · `ndc`/`hri`/`pin` (US) · `fred`/`zcode` (AU) · `lppr` (FR).

**identity-bridge — GTIN family** (all fold to one canonical GTIN-14):
`ean` · `gtin` · `eanGtin8/12/13/14` · `undefinedEanGtinCode` · `usaGtinCode` · `upc10/11/12`.
medipim cross-normalises widths (8/12/13 → zero-filled 14; a true 14 with indicator 1-9 → derived 13);
this engine already folds the GTIN family to GTIN-14 in `Codes`.

**external-ref** (identify the product in *another* system — **do not bridge** for now):
`cbId` (Claude-Bernard) · `ospId` · `offisanteId` · `cisCode` · `publicPageIdentifier`.
**entity-id**: `productId` (medipim's own id == the legacy entity).
**attribute/classification**: `hsCode` (customs) · `pbs` (AU reimbursement class).

**Quirks confirmed:** (1) many delta fields carry a `{field}_` **value prefix** (not just `eanGtin13_`),
stripped at decode; (2) the only field-name ≠ canonical-code mismatch is `cipOrAcl7` → `cip_acl7`.

## Decisions

- **One registry is the source of truth.** `medipim_field → {scheme_atom, classification, canon_rule}`.
  Lives in the ingest (medipim's code knowledge belongs there, not in the generic engine). Adding a
  market = adding rows.
- **Classification drives claim building.** `:identity` → identity claim (bridges in clustering);
  `:external_ref` / `:attribute` → attribute claim (carried on the record, never bridges);
  `:entity_id` is the envelope's legacy entity, not a code claim.
  - *Whether external refs (cbId/ospId/…) should bridge* is deliberately **out of scope** here — it is
    the over-merge/bridging-policy question (own bead). Default for now: they do not bridge.
- **Canonicalization lives in the engine `Codes`** (the single canonical-form function used on both the
  ingest path and the query path — `Substrate`, `Cluster`, `Api`, `PublicId`). Putting national-code
  padding only in the ingest would let a query (`cnk "34567"`) miss a stored padded value
  (`"0034567"`). Real medipim data is full-width, so padding is a no-op there; the only cost is updating
  a few **synthetic** tests that use short fake codes.
- **GTIN family folds via the registry mapping.** Every GTIN-width field maps to the engine atom
  `:gtin`; `Codes` already canonicalizes `:gtin` to GTIN-14. No per-width engine logic needed.
- **The fixture oracle generalises, it is not a production decoder.** `gen.exs` stays a one-off
  bootstrap (the PHP endpoint, gr-867, remains the eventual production path). It gains an
  `(entity_id, source_system, raw_path)` signature, a registry-driven identity set, and a generic
  `{field}_` prefix strip.

## Design

### 1. Code registry (`lib/ingest/`)

A table keyed by medipim field name, e.g. `%{ "cnk" => {:cnk, :identity, {:pad, 7}}, "cipOrAcl7" =>
{:cip_acl7, :identity, {:pad, 7}}, "acl13" => {:acl13, :identity, :trim}, "eanGtin13" => {:gtin,
:identity, :gtin}, "cbId" => {:cb_id, :external_ref, :trim}, … }`. Unknown fields fall back to a
conservative `:attribute`/`:trim` default. Exposes helpers: `scheme(field)`, `classification(field)`,
`identity_field?(field)`, and the set of identity field names (for the gen oracle).

### 2. Engine `Codes`

- Keep GTIN-family folding (`@gtin_schemes`, GTIN-14).
- Add a **pad map** for national short codes: `%{cnk: 7, cip_acl7: 7, pzn: 8, pznAustria: 7, sukl: 7,
  cefip: 7, national_code: 7, cn: 6}` → `canonicalize({scheme, v})` left-pads all-digit values to the
  scheme's width. Trim-only schemes (acl13, cip13, ndc, pdk, …) use the existing pass-through.

### 3. `ClaimMapping`

Replace `@identity_scheme` with registry lookups. Identity-class fields → identity claims (GTIN family
collapses to `:gtin`); external-ref/attribute fields → attribute claims. Generalise `primary/1`: prefer
a national short code (`:cnk` ▸ `:cip_acl7` ▸ other national) ▸ canonical GTIN ▸ `:acl13`/`:cip13` ▸
lowest code.

### 4. gen oracle → `gen.exs`

Parameterise `(entity_id, source_system, raw_path, out_path)`; identity set from the registry; strip a
leading `{field}_` prefix for **any** field whose value carries it; add a CSV reader
(`french_results.csv` → `medipim_fr_347025.raw.jsonl`: split first-2 + last-3 comma fields, the middle
is the events JSON). Keep `gen_422156` reproducible.

### 5. Fixture + tests

`medipim_fr_347025.json` (`source_system: "medipim-fr"`, `legacy_entity: 347025`). Re-derivation test:
347025's listings cluster into **one** product / one SK whose codes include canonical `cip_acl7`,
`acl13` and the EANs (the single-entity `:stable` analog of 422156). Plus the existing BE 422156 path
and unit tests on representative canonicalization (`pzn` → 8, `cip_acl7` → 7, GTIN width folding).

## Out of scope (own bead): over-merge / bridging policy

A from-scratch batch re-derivation clusters on **every** shared identity code with no prior key to gate
against, so two legacy entities sharing a single reused/reassigned barcode silently fuse into one SK
(no collision flagged). medipim never auto-merges a shared-code match — it marks it **Ambiguous** and
flags (`ProductCodeIdentityMatch`, bug MED-11207). French products carry 8+ recycled EANs, so this is
real. The fix (e.g. flag a cluster that fuses ≥2 distinct legacy entities via a shared barcode, using
the legacy entity as a tripwire, not a clustering input) is its **own design** — 347025 alone (one
entity) does not hit it; the cross-entity cases will.

## Executable specification (bead D) — written FIRST

**This is authored before A and B — it is the outside-in acceptance spec that pulls them into
existence (red → green).** A **BDD-style walkthrough test** that doubles as living documentation of
the ubiquitous language — read top-to-bottom it teaches the model before showing the legacy as one
application:

- **Part 1 — `product` and `variant`, from first principles (no legacy).** Build claims directly via
  the engine (`Substrate.claim` → `Cluster.variants` → `IdentityLedger` → `Catalog.project`), with
  **zero** `HistoryEnvelope`/`ClaimMapping`/medipim references. Narrate, Given/When/Then: a **variant**
  is one *source's* identity assertion (a code-set + attributes); a **product** is the cluster of
  variants that share identity codes; combining **multiple sources** yields one golden product whose
  per-source attributes resolve by survivorship; a shared code across two products is a collision, a
  source splitting across code-sets is a split.
- **Part 2 — the legacy as *one* input.** A single example feeding a `HistoryEnvelope` (422156 or the
  347025 fixture) through the ingest (`envelope → claims → re-derive → golden record`) and showing it
  yields the **same** product+variant shape — i.e. the legacy is just one source of claims, not
  special. This is the bridge from the pure model to the medipim takeover.

Emphasis is readability (descriptive `describe`/`test` names + narrative comments), not coverage.

**Red→green convention.** Part 1 and the BE 422156 example are green against today's `main` (engine +
ingest already exist). The French multi-scheme scenarios are written now but `@tag :skip`-ped with
`RED TARGET:` markers, so `main` CI stays green; A un-skips the scheme-canonicalization scenarios and B
un-skips the 347025 fixture scenario, each driving red→green inside its own PR.

## Build order (beads) — spec-first

- **D (gr-ccf) — BDD walkthrough / executable spec. Written FIRST**, the red→green driver (above).
  Ready now (engine + ingest already exist); no blockers.
- **A (gr-6k4) — registry + engine canonicalization.** The registry module, `Codes` pad map +
  GTIN-family confirmation, `ClaimMapping` driven by the registry, `primary/1` generalised. Un-skips +
  greens D's scheme-canonicalization scenarios. Synthetic-test updates. **Depends on D.**
- **B (gr-lmt) — fixture + gen.** Generalise `gen.exs`, CSV → raw.jsonl, decode 347025, FR
  re-derivation test; un-skips + greens D's 347025 scenario. **Depends on A.**
- **C (gr-ose) — over-merge / bridging policy.** The deferred design above. **Depends on A**; needed
  before cross-entity extracts land.
