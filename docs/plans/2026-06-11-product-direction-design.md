# Product direction: ingot as a source-available golden-record product

*Validated in brainstorm, 2026-06-11.*

## Decisions

1. **Audience: generic MDM engine.** Pharma/medipim is the proving ground, not the market.
   The market is any code-identified domain (GTIN, CNK, ISBN, MPN, SKU) with contradicting
   sources.
2. **Form factor: self-hosted service.** Docker + Postgres + HTTP API. Consumers speak HTTP,
   so the Elixir implementation is invisible to them.
3. **Licensing: split, source-available core.**
   - **MIT** — the claims JSON contract, scheme-registry format, validators, client SDKs
     (the integration surface; zero friction wanted here).
   - **FSL** — the engine and service (visible source, free to self-host, no competing
     service; converts to OSS after the FSL window).
   - **Closed** — the steward UI / enterprise layer.
   Rationale: what we need is distribution and trust, not OSS purity. Closed → open is a
   launch; open → closed is a firestorm — so start on the closed side of anything uncertain.
4. **Monetization: product-only.** No consulting. Design partners → self-serve enterprise
   edition → managed single-tenant instances.
5. **Mapping is code, in the customer's language.** No YAML mapping DSL. The product
   contract is a canonical claims JSON format; customers write their export-and-map script
   in whatever they live in. The Elixir behaviour remains as the internal adapter layer
   (the medipim pipeline is the worked reference adapter).
6. **Genericity boundary: code-identified domains only.** No fuzzy/ML matching of names and
   addresses (Splink/Zingg territory). Deterministic, evidence-based, steward-gated
   resolution is the differentiator, not a limitation to apologize for.

## 1. Positioning

**One-liner:** Ingot is a source-available golden-record engine for code-identified data:
it turns contradicting sources into a clean, auditable, time-travelable catalog — and never
merges without evidence.

**Buyer pain:** "We have three systems that disagree about what product 422156 is, and
nobody can say why."

**Differentiators** (vs. OSS matching tools, which do matching but not governance):
deterministic evidence-based resolution, identity ledger with merge/split lineage, gated
merges (undecidable → human review), bitemporal time travel, stable public identity with
redirect-on-reassign. "Auditable beats clever" is the brand.

**Competitive frame:** below enterprise MDM (Reltio, Semarchy — six figures, sales-heavy),
beside the OSS resolution tools (Splink, Zingg, dedupe). The empty quadrant:
*developer-first, deterministic, governed* master data.

## 2. Monetization & funnel

**Free tier** (FSL engine + service, self-hosted): full resolution engine, HTTP API, claims
contract + validators (MIT), dry-run migration reports, stewardship via API/CLI. The
model's honesty ("undecidable → steward review") must work in the free tier.

**Paid** (the governance layer): steward web UI (conflict queue, merge approval, four-eyes
workflow, assignments), SSO/SAML + RBAC, audit/compliance exports, HA deployment support.

**Funnel:** engine on GitHub → customer maps one source to claims in their own language →
free dry-run report ("1,400 conflicts, 230 merge candidates, 12 CNK collisions") → pain is
visible and quantified → the paid steward edition is the tool for working exactly that
queue. The free tier creates the demand the paid tier satisfies.

**Phases:**
1. Design partners — 2–3 discounted annual-prepaid enterprise licenses before the steward
   UI is finished, in exchange for shaping it on their real data.
2. Self-serve enterprise edition — license key bought online, no sales motion.
3. Managed single-tenant instances — ops premium.

**Pricing:** per steward seat + record-volume instance tiers. No API-call metering (it
would punish the integration usage we want). Anchor against six-figure enterprise MDM;
land around €500–2,000/month.

## 3. Product surfaces & architecture

Three artifacts; the current repo contains the seeds of each:

1. **The contract (MIT).** Separate package: claims JSON Schema, scheme-registry format
   (declare code types: normalizers, checksum rules, equivalence families like GTIN),
   validators, thin client SDKs. *Seed:* the contract-C `HistoryEnvelope` spec + the
   data-driven code registry, generalized and extracted.
2. **The engine + service (FSL).** The `lib/` engine unchanged in spirit (pure functions,
   event-sourced, folds over the log), fronted by `api/` extended with a write side:
   `POST /claims` (batch submission), `POST /dry-run` (full pipeline, nothing committed,
   returns the report), cutover (commit, mint keys, seed the steward queue). Re-runs
   converge: deterministic claim identity makes iterative migrations idempotent. The
   medipim ingest (`lib/ingest/`) stays as the worked reference adapter. Stewardship is
   exposed via API/CLI here, with four-eyes enforced by the engine, not the UI.
3. **The steward UI (closed).** Web app over the stewardship API: conflict queue,
   merge-candidate review with evidence side-by-side, lineage browsing, audit exports,
   SSO/RBAC. *Seed:* the `viz/` time machine — its as-of timeline is the lineage browser,
   repurposed from demo to product.

**Data flow:** customer script → claims JSON → `POST /dry-run` → report → fix mapping,
repeat → cutover → golden catalog + steward queue → read API (`resolve_key`, `lookup`,
`changes_since`) serves downstream systems.

## 4. Roadmap & validation milestones

- **M1 — Extract the contract.** Claims JSON Schema + scheme-registry format + validator;
  refactor `claim_mapping.ex` to consume canonical claims; medipim becomes the reference
  adapter. *Done when:* existing suite passes with claims flowing through the new contract.
- **M2 — The write side.** `POST /claims`, `POST /dry-run` + report, cutover, idempotent
  re-runs; stewardship API/CLI (queue, approve/reject, four-eyes). *Done when:* the
  medipim migration runs end-to-end over HTTP.
- **M3 — Genericity gate.** Migrate a second, non-pharma public dataset (book records with
  ISBN-10/13 from two overlapping sources) with **zero engine changes** — config and
  adapter only. If this fails, fix the engine before anyone is watching.
- **M4 — Package & launch.** `docker compose up` quickstart, docs site, MIT/FSL licensing
  applied, repo public, launch post with the viz as the centerpiece demo.
- **M5 — Design partners.** Polish the dry-run report into the funnel artifact; recruit
  2–3 partners.
- **M6 — Steward UI MVP**, shaped by partner feedback. First self-serve sale closes the
  loop.

**Honest checkpoints:** if ~3 months after M4 nobody outside the founder's network has run
a dry-run, the distribution thesis is wrong — revisit before building M6. The steward UI is
deliberately last: it is the most expensive artifact and the one design partners de-risk.
