import { useMemo, useState } from "react";
import { motion } from "motion/react";
import type { ProductGroup, RealScene, TimelineEvent, VariantView } from "../lib/types";

const chipClass = (code: string) =>
  code.startsWith("cnk:") ? "chip cnk" : code.startsWith("gtin:") ? "chip gtin" : "chip";

// The engine's primary-id priority: a national SHORT code (CNK first) is the trusted spine, then a
// GTIN, then anything else (mirrors ClaimMapping's @national_primary / PrimaryProductCodeDetermination).
const NATIONAL = ["cnk:", "cip_acl7:", "cefip:", "pzn:", "sukl:", "pzn_austria:", "national_code:", "cn:"];
function priorityRank(code: string): number {
  const ni = NATIONAL.findIndex((p) => code.startsWith(p));
  if (ni >= 0) return ni; // national short codes first, in their own order
  if (code.startsWith("gtin:")) return 100; // then GTINs
  return 200; // then everything else
}
// Codes listed in priority order — the first is the variant's primary identifier.
function orderedCodes(codes: string[]): string[] {
  return [...codes].sort((a, b) => priorityRank(a) - priorityRank(b) || a.localeCompare(b));
}

// A short, data-driven note for a variant, derived from the timeline (when it was minted) and its
// codes (whether it carries a national code — the trusted spine — or only a GTIN).
function explain(variant: VariantView, timeline: TimelineEvent[]) {
  const mint = timeline.find((e) => e.type === "MINT" && e.key === variant.key);
  const hasCnk = variant.codes.some((c) => c.startsWith("cnk:"));
  return {
    when: mint?.date,
    anchor: hasCnk
      ? "anchored on a national code (CNK) — the trusted spine"
      : "anchored on a GTIN barcode — no national code",
  };
}

function VariantRow({
  variant,
  timeline,
  flagged,
}: {
  variant: VariantView;
  timeline: TimelineEvent[];
  flagged: boolean;
}) {
  const { when, anchor } = explain(variant, timeline);
  const codes = orderedCodes(variant.codes);
  return (
    <div className="variant-row">
      <div className={`card variant${flagged ? " flagged" : ""}`}>
        <div className="card-key">
          variant <b>{variant.key}</b>
        </div>
        <div className="chips">
          {codes.map((c, i) => (
            <span key={c} className={`${chipClass(c)}${i === 0 ? " primary" : ""}`}>
              {c}
            </span>
          ))}
        </div>
      </div>
      <div className="variant-explain">
        {when && <span className="when">first seen {when}</span>}
        <span>{anchor}.</span>
        <span className="primary-note">
          primary id <b>{codes[0]}</b>
        </span>
        {variant.sources.length > 0 && (
          <span className="sources">
            from source{variant.sources.length > 1 ? "s" : ""}{" "}
            <b>{variant.sources.map((s) => `org ${s}`).join(" + ")}</b>
          </span>
        )}
      </div>
    </div>
  );
}

// The vertical ⚠ link that sits between two stacked variant cards, with the gate explained beside it.
function MergeLinkV() {
  return (
    <motion.div
      className="merge-link-v"
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      transition={{ duration: 0.4 }}
    >
      <div className="rail">
        <span className="merge-flag">⚠ merge proposed · gated</span>
      </div>
      <div className="merge-explain">
        Their codes now overlap — but each key was <b>established on its own first</b>. A shared code can
        mean "same product" <i>or</i> a reused barcode, so the over-merge guard <b>proposes</b> a merge and
        waits for a steward instead of fusing them automatically.
      </div>
    </motion.div>
  );
}

// Keys whose codes no source still claims — shown so a retired key reads as "retired", not "vanished".
function RetiredStrip({ retired }: { retired: VariantView[] }) {
  return (
    <motion.div className="retired" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
      {retired.map((v) => (
        <div className="retired-row" key={v.key}>
          <span className="retired-tag">⊘ retired</span>
          <b>{v.key}</b>
          {v.sources.length > 0 && <span className="retired-src">org {v.sources.join(", ")}</span>}
          <span className="retired-codes">{v.codes.join(" · ")}</span>
          <span className="retired-why">— no source still claims this code (a swapped-out barcode)</span>
        </div>
      ))}
    </motion.div>
  );
}

// A legacy product and the golden variants it resolves into, stacked vertically with explanations.
function ProductBox({
  group,
  proposals,
  retired,
  timeline,
}: {
  group: ProductGroup;
  proposals: string[][];
  retired: VariantView[];
  timeline: TimelineEvent[];
}) {
  const flaggedKeys = new Set(proposals.flat());
  const linked = proposals.length > 0 && group.variants.length >= 2;
  const n = group.variants.length;

  return (
    <div className="product-box">
      <div className="product-head">
        legacy product <b>{group.product}</b> ·{" "}
        <span className={n > 1 ? "count-2" : "count-1"}>
          {n} golden variant{n === 1 ? "" : "s"}
        </span>
        {retired.length > 0 && <span className="retired-count"> · {retired.length} retired</span>}
      </div>

      <div className="variants-vertical">
        {group.variants.map((v, i) => (
          <div key={v.key}>
            <VariantRow variant={v} timeline={timeline} flagged={flaggedKeys.has(v.key)} />
            {linked && i === 0 && n >= 2 && <MergeLinkV />}
          </div>
        ))}
      </div>

      {retired.length > 0 && <RetiredStrip retired={retired} />}
    </div>
  );
}

// Scene 1 — the as-of time machine, finer-grained. Drag the date; watch legacy product 422156 resolve
// from 1 → 2 golden variants and the over-merge guard raise a standing proposal it won't auto-apply.
export default function TimeMachine({ scene }: { scene: RealScene }) {
  const { dates, timeline } = scene;
  const n = dates.length;
  const [index, setIndex] = useState(n - 1);

  // date -> the kind of identity event that lands on it (for colouring the axis ticks).
  const eventOn = useMemo(() => {
    const m = new Map<string, string>();
    for (const e of timeline) if (!m.has(e.date)) m.set(e.date, e.type);
    return m;
  }, [timeline]);

  const activeDate = dates[index];
  const asOf = scene.asOf[activeDate];
  const variantCount = asOf.products.reduce((s, p) => s + p.variants.length, 0);
  const proposalCount = asOf.proposals.length;
  const pct = (i: number) => (n > 1 ? (i / (n - 1)) * 100 : 0);

  return (
    <div className="panel">
      <div className="readout">
        as-of <b>{activeDate}</b> ·{" "}
        <span className={variantCount > 1 ? "count-2" : "count-1"}>
          {variantCount} golden variant{variantCount === 1 ? "" : "s"}
        </span>
        {proposalCount > 0 && <span className="readout-flag"> · ⚠ {proposalCount} merge proposed</span>}
      </div>

      <div className="axis-wrap">
        <div className="axis">
          <div className="axis-fill" style={{ width: `${pct(index)}%` }} />

          {dates.map((d, i) => {
            const ev = eventOn.get(d);
            return (
              <div
                key={d}
                className={[
                  "tick",
                  i <= index ? "passed" : "",
                  ev === "MINT" ? "mint" : "",
                  ev === "FLAG" ? "flag" : "",
                  ev === "MEMBERS" ? "identity" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
                style={{ left: `${pct(i)}%` }}
                title={ev ? `${d} · ${ev}` : d}
              />
            );
          })}

          <div className="handle" style={{ left: `${pct(index)}%` }} />

          <input
            className="range"
            type="range"
            min={0}
            max={n - 1}
            step={1}
            value={index}
            aria-label="as-of date"
            onChange={(e) => setIndex(Number(e.target.value))}
          />
        </div>

        <div className="axis-ends">
          <span>{dates[0]}</span>
          <span>← drag the date →</span>
          <span>{dates[n - 1]}</span>
        </div>

        <div className="legend">
          <span>
            <i className="dot mint" /> identity minted
          </span>
          <span>
            <i className="dot flag" /> merge flagged
          </span>
        </div>
      </div>

      <div className="stage">
        {asOf.products.map((p) => (
          <ProductBox
            key={String(p.product)}
            group={p}
            proposals={asOf.proposals}
            retired={asOf.retired}
            timeline={timeline}
          />
        ))}
      </div>

      <p className="caption">
        <b>Sources</b> are the legacy orgs that listed the product (medipim org IDs — here 1034, 1035, 44).
        Re-derivation pools their claims by <b>shared code</b>, not by the legacy grouping: orgs 1034 + 1035
        share the CNK → one variant; org 44 carried its <i>own</i> barcode (no CNK) for years → a{" "}
        <b>second variant</b>. When org 44 finally lined up its barcode (2023) and the CNK (2024), the codes
        overlap — but the <b>over-merge guard</b> raises a standing proposal rather than silently merging.
        Drag back to <b>2018–2023</b> to watch org 44 appear (and its now-retired old-barcode key, SK_2).
      </p>

      <p className="footnote">
        Finer-grained prototype: this folds the <i>raw</i> per-event identity deltas (true dates), not the
        shipped pass's per-listing collapse. Generated by <code>mix run temporal_export.exs</code> from the
        real engine primitives.
      </p>
    </div>
  );
}
