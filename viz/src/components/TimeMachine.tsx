import { useMemo, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import type { RealScene } from "../lib/types";
import GoldenCard from "./GoldenCard";

// Scene 1 — the as-of time machine. Drag the date; the golden record materializes at the mint.
// The browser folds nothing: it reads scene.asOf[date], precomputed by the real Temporal engine.
export default function TimeMachine({ scene }: { scene: RealScene }) {
  const { dates, mintDate } = scene;
  const n = dates.length;
  const [index, setIndex] = useState(n - 1);

  const identityDates = useMemo(
    () => new Set(scene.claims.filter((c) => c.kind === "identity").map((c) => c.date)),
    [scene.claims],
  );
  const mintIndex = dates.indexOf(mintDate);

  const activeDate = dates[index];
  const variants = scene.asOf[activeDate]?.variants ?? [];
  const pct = (i: number) => (n > 1 ? (i / (n - 1)) * 100 : 0);

  return (
    <div className="panel">
      <div className="readout">
        as-of <b>{activeDate}</b> ·{" "}
        <span className={variants.length ? "count-1" : "count-0"}>
          {variants.length} variant{variants.length === 1 ? "" : "s"}
        </span>
      </div>

      <div className="axis-wrap">
        <div className="axis">
          <div className="axis-fill" style={{ width: `${pct(index)}%` }} />

          {dates.map((d, i) => (
            <div
              key={d}
              className={[
                "tick",
                identityDates.has(d) ? "identity" : "",
                i <= index ? "passed" : "",
                d === mintDate ? "mint" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              style={{ left: `${pct(i)}%` }}
            />
          ))}

          {mintIndex >= 0 && (
            <div className="mint-flag" style={{ left: `${pct(mintIndex)}%` }}>
              ✦ MINT {mintDate}
            </div>
          )}

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
      </div>

      <div className="stage">
        <AnimatePresence mode="popLayout">
          {variants.length > 0 ? (
            variants.map((v) => <GoldenCard key={v.key} variant={v} />)
          ) : (
            <motion.div
              className="ghost"
              key="ghost"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
            >
              no resolvable identity yet — 422156 has no identity claim on or before {activeDate}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <p className="footnote">
        Drag back across <code>✦ MINT {mintDate}</code> and the product <i>un-becomes</i> identified —
        the 0 → 1 step a flat snapshot throws away. Every state here is the real <code>Temporal</code>{" "}
        engine via <code>mix run temporal_export.exs</code>.
      </p>
    </div>
  );
}
