// One-line on-screen caption per (chapter, step) — keyed "chapterId/stepId". On screen rather than
// speaker notes, so the demo also works self-driven when shared as a link.

const NARRATION: Record<string, string> = {
  // 1 — the old way (illustration)
  "oldWay/two-records":
    "Two imports describe what looks like the same sunscreen — different barcodes, different weights.",
  "oldWay/match": "A fuzzy name match links them. Plausible. Unverifiable.",
  "oldWay/merge":
    "The records are fused in place. The other weight, the other image, and who-said-what are gone.",
  "oldWay/import":
    "A later import updates the fused record. Every future import builds on the mistake — and nothing recorded that it happened.",

  // 2 — claims, not records
  "claims/first-claim":
    "A source asserts claims about a code — not rows in a master table. The golden record on the right is derived from them.",
  "claims/first-attribute":
    "The weight is anchored to the barcode, not to a matched record. Evidence first; conclusions derived.",
  "claims/second-source":
    "A second source shares the barcode, so the cluster grows. Nothing was overwritten — both sources' claims stand.",
  "claims/media":
    "An image attaches by code too. Everything on the golden card is a fold over the log — replayable to any moment.",

  // 3 — who wins?
  "priority/one-product": "Three sources list the same product. One golden record — nothing to disagree about yet.",
  "priority/marketplace-weight": "The marketplace asserts a weight. It wins by default: it's the only candidate.",
  "priority/supplier-weight":
    "The supplier disagrees. Its tier outranks the marketplace — the field flips, and the losing claim is kept.",
  "priority/manufacturer-weight":
    "The manufacturer speaks. Highest tier wins; the full ranking stays visible as provenance.",
  "priority/color-tie":
    "Manufacturer and supplier share a tier and disagree on colour. The engine doesn't guess — it flags.",
  "priority/steward-pick":
    "A steward decides. The pick is recorded as an event — who, what, when — not an overwrite.",

  // 4 — identity has a "when" (the embedded time machine drives itself)
  "machine/scrub":
    "The real product 422156: drag the date and watch identity become resolvable. A snapshot would have hidden all of this.",

  // 5 — the guard
  "guard/disjoint":
    "Two identities, each established on its own evidence. Nothing connects them — yet.",
  "guard/bridge":
    "A late barcode bridges them. Same product, or a reused barcode? The engine proposes a merge — it never silently applies one.",

  // 6 — the mistake is cheap
  "mistake/two-products": "Two sunscreens from two manufacturers. Similar names. Two golden records, two keys.",
  "mistake/wrong-merge": "A steward merges them — the names looked alike. The engine records the decision and obeys.",
  "mistake/contradiction":
    "The fused record now carries two same-tier weights. The contradiction surfaces because the evidence was never destroyed.",
  "mistake/split": "The steward splits the stranger's codes back out. One recorded operation — not a data-repair project.",
  "mistake/healed":
    "Every attribute and image re-homed to its code's new key. Nothing re-imported, nothing lost — the mistake was cheap.",
};

export function caption(chapterId: string, stepId: string): string {
  return NARRATION[`${chapterId}/${stepId}`] ?? "";
}
