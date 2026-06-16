# Canonical claims contract + scheme registry — the MIT product contract

The integration surface customers code against, in **their own language**: a customer script
exports source data, maps it to canonical **claims JSON**, and submits batches to the engine
(`POST /v1/claims`). This document formalizes the wire format the engine already speaks
(`CanonicalClaims.to_engine/2`, pinned by `api/test/writes_test.exs`) — it does **not** invent a
new one. Machine-readable schemas live beside it:

- `contract/claims.schema.json` — a claims submission batch (JSON Schema, draft 2020-12).
- `contract/scheme_registry.schema.json` — scheme-registry declarations (JSON Schema, draft 2020-12).

Relationship to contract C (`docs/HISTORY_ENVELOPE.md`): the envelope is the **backfill**
boundary for a legacy event log (`POST /v1/backfill/envelopes`); this contract is the **live**
boundary for everything else. Both feed the same reconcile pipeline.

---

## Batch envelope

A submission is one JSON object with one key:

```jsonc
{ "claims": [ /* claim objects — see below */ ] }
```

A batch validates **whole**: one invalid claim rejects the entire batch with per-index reasons,
and **nothing partial enters the log**. There is no partial acceptance.

### Success response (`200`)

```jsonc
{
  "accepted": 3,        // claims accepted (backfill: envelopes accepted)
  "skipped": 0,         // replayed no-ops: backfill envelopes already seen; live claims whose slot already holds identical content
  "claims": 3,          // claim events appended to the log
  "events": [ /* what identity DID: minted | members_changed | merged | split | merge_proposal */ ],
  "flagged": [ {"type": "merge_proposal", "keys": ["SK_1", "SK_3"]} ]
}
```

`flagged` is the important part: convergences the over-merge guard **gated** for a steward.
A live claim bridging two **established** keys is flagged, never auto-merged.

### Error response (`422`)

```jsonc
{ "errors": [ {"index": 1, "error": "code must be \"scheme:value\", got \"not-a-code\""} ] }
```

| field   | type            | notes |
|---------|-----------------|-------|
| `index` | integer \| null | zero-based position of the offending claim in `claims`. `null` when the failure is structural (body not `{"claims": [...]}`, or `claims` not a list). |
| `error` | string          | human-readable reason. **Not** machine-stable — match on `index`, not on the message text. |

---

## Claim shape — common fields

Every claim is an object with a `kind` discriminator. Fields common to all kinds:

| field        | type   | notes |
|--------------|--------|-------|
| `kind`       | string | `identity` \| `attribute` \| `media` \| `grouping` \| `edge`. Anything else rejects. |
| `source`     | string | **source attribution** — who asserts this claim (e.g. `"medipim"`, an org id, a feed name). Resolution ranks sources; the contract just records them. Free-form, non-empty. |
| `valid_from` | string, optional | ISO 8601 **date** (`"2024-03-01"`). See bitemporal fields below. |

Unknown extra fields are **ignored**, not rejected (actual behavior of the parser's pattern
matching). Do not rely on this — a stricter validator may reject them later (open question 6).

### Bitemporal fields: `valid_from` vs `recorded_at`

- **`recorded_at`** — when the engine learned the fact. **Server-side, always the submission
  date.** Clients cannot supply it on the live contract (the backfill envelope is the path for
  historical `recorded_at`).
- **`valid_from`** — when the fact became true in the world. Optional; defaults to
  `recorded_at`. Supply it when a change applied earlier than it was reported (back-dating).
  Date precision only — no time component (open question 3).

### Codes are `"scheme:value"` strings

Everywhere a claim carries a code, it is a single string: the scheme name, a colon, the value.
Split on the **first** colon — the value may itself contain colons. Both halves must be
non-empty.

```text
"cnk:1000001"   "gtin:05012345678900"   "ean:5012345678900"   "mpn:AB-1234"
```

- **Known schemes** are the registry's engine-native names (see the scheme registry below).
  The engine canonicalizes per scheme: the GTIN family (`gtin`/`ean`/`upc`) folds to a
  14-digit zero-filled GTIN, padded national schemes left-pad to their width, everything else
  is trimmed.
- **Unknown schemes pass through** as opaque strings — conservative, never rejected, never
  bridging-grade. `"mystery:42"` is stored as-is and treated as a non-identifying code.

---

## Node claims

### `identity` — what a listing IS

The clustering input: a source's listing (`ref`) asserts a set of codes. Codes **bridge**
listings into one identity (subject to each scheme's class and bridge grade).

```jsonc
{
  "kind": "identity",
  "source": "medipim",
  "ref": "P-1",                                   // the source's OWN listing id — stable per source
  "codes": ["cnk:1000001", "gtin:05012345678900"], // non-empty array of "scheme:value"
  "valid_from": "2024-03-01"                       // optional
}
```

`ref` is the claim's anchor within the source: a later `identity` claim with the same
`(source, ref)` **replaces** the earlier code-set (last-wins per slot — see idempotency).

**Entity lanes.** Every scheme belongs to one entity lane (`product` | `substance` |
`description` | `media`, declared in the scheme registry; unlisted schemes are `product`).
An identity claim routes to its codes' lane and clusters only there — codes mixing two lanes
**reject**. The optional `"entity"` field names the lane explicitly; it is required only when
every code is lane-neutral (the engine-minted `uuid` scheme):

```jsonc
{
  "kind": "identity",
  "source": "steward",
  "ref": "draft-desc-1",
  "codes": ["uuid:0d6f8a3e-..."],   // minted by the engine — carries no lane of its own
  "entity": "description"
}
```

### `attribute` — a fact about a coded thing

```jsonc
{
  "kind": "attribute",
  "source": "medipim",
  "code": "cnk:1000001",   // the code the fact is anchored to
  "field": "name",          // free-form field name; localized fields use "field:locale" ("name:fr")
  "value": "Sunscreen"      // string | number | boolean
}
```

Attributes never bridge; survivorship decides which source's value wins per `(code, field)`.

### `media` — an asset attached to a coded thing

```jsonc
{
  "kind": "media",
  "source": "medipim",
  "asset": "img-001",               // the asset id in the submitting DAM/source
  "target": "cnk:1000001",          // the code the asset attaches to
  "uri": "https://cdn.example/img-001.jpg",
  "role": "primary"                  // optional; "primary" — ANY other value (or absence) means secondary
}
```

## Edge claims

### `grouping` — code → legacy product id

The continuity edge to a predecessor system: this code belonged to legacy product `product`.
Drives legacy-id assignment (a minted key inherits the legacy id its codes group to).

```jsonc
{
  "kind": "grouping",
  "source": "medipim",
  "code": "cnk:1000001",
  "product": 422156          // integer — the legacy system's own product id
}
```

### `edge` — a typed relationship between two coded records

Both endpoints are codes, resolved to their **current owner key at read time** — so the edge
survives merge/split on either side with zero rewrites. The relation must be declared in the
scheme registry with a lane signature; a mismatched endpoint **rejects**:

| relation    | from        | to                      | feeds |
|-------------|-------------|-------------------------|-------|
| `contains`  | product     | substance               | the product's substances |
| `describes` | description | product \| substance    | derived product-page descriptions (direct, or via every product containing the substance) |
| `depicts`   | media       | product \| substance    | the product's media |
| `member_of` | product     | collection (unchecked)  | categories |

```jsonc
{
  "kind": "edge",
  "source": "vidal",
  "from": "text_id:D-1042",          // the asserting entity, by code
  "relation": "describes",
  "to": "substance_id:PARA",          // the target entity, by code
  "valid_from": "2024-03-01"          // optional
}
```

Edges **union across sources** (any live source ⇒ the edge holds); a steward hides one derived
description↔product pairing with a four-eyes-gated `suppress` edge, leaving the substance tag
intact. Visibility is **derived, never stored**: a product newly claiming a substance instantly
shows that substance's descriptions, because the page is a fold over the edges, not a copy.

> Collection membership rides the standard `edge` claim — submit
> `{"kind":"edge","relation":"member_of","from":"<product code>","to":"<collection code>"}`,
> and the engine derives categories from it. The engine also still accepts the legacy
> `member_of` claim kind and lowers it to exactly this edge, so backfill logs keep working.
> What remains open is only how a collection namespace is spelled as a `to` code (open
> question 1).

---

## Idempotency expectations

- **Live claims are slot-keyed, last-wins.** Each claim occupies a deterministic slot —
  `identity`: `(source, ref)`; `attribute`: `(source, code, field)`; `media`:
  `(source, asset, target)`; `grouping`: `(source, code)` — and the current view keeps the
  latest claim per slot. Re-submitting a claim identical to its slot's current content is
  **skipped** (counted in `skipped`, nothing appended); re-submitting with a changed payload
  updates that slot only. Claim identity is the content `(source, kind, payload, valid_from)`
  after code canonicalization — `recorded_at` is excluded, so the same claim resubmitted on a
  later day is still the same claim.
- **Re-runs converge.** Because claim identity is deterministic, iterating on a mapping script
  and re-submitting is safe: keys stay stable, replays are no-ops without log growth (backfill:
  per-envelope content fingerprints; live: per-slot claim identity), and the same evidence
  produces the same resolution.
- **Established keys never auto-merge.** New evidence bridging two established keys yields a
  `merge_proposal` flag for steward review, regardless of how often it is re-submitted.

---

## The scheme registry — declaring code types

What the engine knows about a scheme is **data, not code** (precedent: `CodeRegistry` —
adding a market is a table change). A registry document declares the schemes a deployment
speaks; `contract/scheme_registry.schema.json` is its schema.

```jsonc
{
  "schema_version": "1",
  "schemes": [
    {
      "name": "gtin",                  // the canonical engine-native scheme name
      "class": "identity",             // identity | external_ref | attribute | entity_id
      "bridge_grade": "barcode",       // national | barcode | none — the over-merge guard's axis
      "normalizer": {"kind": "gtin"},  // trim | pad_left(width) | gtin
      "checksum": "gtin_mod10",        // none | gtin_mod10
      "equivalence_family": "gtin",    // codes in one family compare equal after normalization
      "aliases": ["ean", "upc"]        // accepted wire spellings that fold to `name`
    },
    {
      "name": "cnk",
      "class": "identity",
      "bridge_grade": "national",
      "normalizer": {"kind": "trim"},
      "checksum": "none"
    },
    {
      "name": "cb_id",
      "class": "external_ref"          // identifies the product in ANOTHER system — never bridges
    }
  ]
}
```

### Declaration fields

| field                | required | notes |
|----------------------|----------|-------|
| `name`               | yes      | canonical scheme name — the string before the colon in `"scheme:value"`. Lowercase snake_case. |
| `class`              | yes      | how clustering uses the code: **`identity`** bridges listings; **`external_ref`** identifies the thing in another system and is carried but **never bridges**; **`attribute`** is a non-identifying classification (customs code, reimbursement class); **`entity_id`** is the source system's own record id — not a code claim at all. |
| `bridge_grade`       | no       | the over-merge guard's **orthogonal** axis, deliberately distinct from `class`: a merge bridged by a **`national`** code is trusted; one bridged *solely* by a **`barcode`**-grade code (reusable/reassignable GS1 codes — `gtin`, `acl13`, `cip13`) is suspect and gated; **`none`** (default) is not a bridge. Note `acl13`/`cip13` are `class: identity` (they DO bridge) yet barcode-grade here. |
| `normalizer`         | no       | canonicalization rule: `{"kind": "trim"}` (default — whitespace trim only); `{"kind": "pad_left", "width": N}` (all-digit values shorter than N left-pad with zeros — e.g. `cip_acl7`:7, `pzn`:8, `cn`:6); `{"kind": "gtin"}` (8/12/13/14-digit values zero-fill to GTIN-14; non-GTIN-shaped values pass through untouched). |
| `checksum`           | no       | validity rule for **validators**: `"none"` (default) or `"gtin_mod10"` (GS1 mod-10 check digit). The engine does **not** enforce checksums at the submission boundary today — see open question 2. |
| `equivalence_family` | no       | schemes sharing a family denote the same code space at different widths/spellings; after normalization their values compare equal. Precedent: the **GTIN family** — `ean`, `upc`, and medipim's `eanGtin8/12/13/14` all fold to `gtin`, and an EAN-13 equals its zero-padded GTIN-14. |
| `aliases`            | no       | alternative scheme spellings accepted on the wire that fold to `name` (e.g. `"ean:5012345678900"` is accepted and canonicalized as `gtin`). |

### Semantics inherited from the engine (normative behavior)

- **Unknown schemes**: a scheme name not in the registry is accepted, passed through as an
  opaque string, trim-normalized, classified as a non-bridging `attribute`, bridge grade
  `none`. Registries extend coverage; they never gate submission.
- **Restricted GTINs**: GTIN-family values with GS1 prefix `02` or `20–29` (in-store /
  variable-measure) are not globally unique and are excluded from bridging regardless of the
  scheme's declared class.
- **Never-bridging schemes**: `mpn` and `supplier_ref` are accepted identity-claim codes but
  excluded from bridging (manufacturer part numbers and supplier refs are shared across
  distinct trade items).

---

## Open questions (underspecified in the current format)

1. **The `member_of` `to`-side collection identifier is unstandardized.** Collection
   membership now rides a standard `edge` claim (`relation: "member_of"`, `from` a product code,
   `to` a collection code) and the engine derives categories from it — so `member_of` *is* on
   the wire. What is still open is the *scheme* for the `to` code: how a category/brand/labo
   namespace is spelled as `scheme:value` (its lane is unchecked today). The medipim backfill
   adapter still emits the legacy `{"kind": "member_of", "source", "code", "collection",
   "member"}` claim, which the constructor lowers to this edge.
2. **Checksums are advisory.** `gtin_mod10` is implemented (`Codes.valid_gtin?/1`) but not
   called at the submission boundary — a syntactically valid GTIN with a bad check digit is
   accepted. Should the MIT validator warn, and should the engine optionally reject?
3. **`valid_from` is date-only.** No time-of-day, no timezone. Contract C uses unix seconds;
   the live contract uses ISO dates. Sub-day validity ordering is unspecified.
4. **`recorded_at` is not client-suppliable on the live path.** Historical loads must go
   through the backfill envelope. Is that split permanent, or should live claims accept a
   bounded `recorded_at` for near-real-time feeds with delivery lag?
5. **`media.role` is forgiving.** Any value other than the string `"primary"` — including
   typos — silently becomes `secondary`. The schema constrains it to the enum; the engine
   today does not.
6. **Extra fields are ignored.** The parser pattern-matches required fields and ignores the
   rest, so typoed optional fields (e.g. `"valid_form"`) silently vanish. The schemas mirror
   actual behavior (`additionalProperties` left open); a strict validation mode is a candidate.
7. **No batch fingerprint on live claims.** Live replays are deduped **per claim** (a claim
   whose slot already holds identical content is skipped — no log growth), not per batch. Is a
   client-supplied batch idempotency key (ack/reject a whole batch by key) still wanted?
8. **No batch size limit is specified.** The whole-batch-validates rule makes very large
   batches all-or-nothing; a documented maximum (and a recommended chunking size) is open.
9. **Scheme-name grammar.** The schema requires lowercase snake_case for *declared* names
   (matching every existing scheme), but the wire accepts any non-empty scheme string.
