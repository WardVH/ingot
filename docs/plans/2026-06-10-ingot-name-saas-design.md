# Ingot — product name & SaaS viability

Date: 2026-06-10
Status: validated in brainstorm (name + positioning decided; commercial steps pending)

## Decision

The golden-record engine's product name is **Ingot**.

An ingot is what comes out of smelting: ore from many sources, melted down, cast into one
standardized, stamped, tradeable bar — which is exactly what this engine does to product data.
Short, typeable, works as CLI (`ingot push`), package, and domain (`ingot.dev` / `getingot.com`).
Collision check (2026-06-10, preliminary web/domain search — formal EUIPO check is next-step 1):
no obvious data-tooling collisions; nearest are Inngot (IP valuation, different spelling) and
Ingot Brokers (forex).

The metaphor extends to feature vocabulary, end to end:

| Term | Meaning in metallurgy | Meaning in Ingot |
|---|---|---|
| **Ingot** | standardized cast bar | the golden record |
| **mint** | strike new coin | identity creation (the engine's `Events.IdentityMinted` event) |
| **assay** | test gold purity | merge verification / the over-merge guard |
| **hallmark** | certification stamp | the per-record audit trail |

Rejected: **Assay** (best meaning, but biotech owns the SEO), **Crucible** (Atlassian's
code-review product — stale association), **Smelt** (unserious), **Cupel** (unpronounceable),
**Hallmark** (culturally owned by greeting cards), **Mint/Karat/Aurum** (taken/overused).

## Positioning

> **Ingot — golden records as an API.** POST your product catalogs from any source; get back one
> deduplicated, explainable, auditable record per real-world product — in minutes, no data team.

- **Market verdict:** viable as a focused, bootstrappable niche SaaS; not a horizontal
  venture-scale play. Enterprise MDM (Reltio, Tamr, Stibo) owns the top; OSS (Splink, Zingg)
  owns the DIY bottom; API-first incumbents (Tilores, Senzing, AWS Entity Resolution) all lead
  with fuzzy ML matching of people/companies. dedupe.io ("Stripe for dedup") shut down —
  credit-card devs alone don't sustain this.
- **The gap:** deterministic, code-based, product-shaped resolution (GTINs, national codes,
  explainable merges, steward review, as-of queries). For product data, fuzzy ML is the wrong
  tool and enterprise MDM is overkill. No direct owner.
- **Wedge vs moat:** lead with time-to-first-merge (Stripe-grade DX) to win the developer;
  the event-sourced audit trail + temporal queries are the moat — the reason customers can't
  leave and compliance-heavy verticals (pharma) pick us.

## Next steps (beads filed under the ingot epic)

1. (gr-c3i) Reserve name assets — domains, GitHub org, package names; quick EUIPO class-42 check.
   Human decision: costs money.
2. (gr-gju) Rebrand public surfaces — OpenAPI spec title, API docs, README.
3. (gr-25s) Time-to-first-merge quickstart — a curl-able 5-minute demo on the 422156 fixture;
   this is the positioning made tangible.
4. (gr-o02) Landing page copy — one-liner, wedge, audit-moat story, waitlist CTA.
5. (gr-uo0) Customer discovery — list 10 product-data prospects (aggregators, marketplaces,
   pharma data) and validate the wedge before building more.
