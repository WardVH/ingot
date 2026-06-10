import { useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import type { SyntheticScene } from "../lib/types";

const chipClass = (code: string) => (code.startsWith("cnk:") ? "chip cnk" : "chip gtin");

// Scene 2 — the over-merge guard, temporally. Step d1 → d2: a late barcode bridges two established
// keys; the engine FLAGS a merge proposal instead of silently merging. Both keys survive.
// `embedded` renders it as a story chapter: the shell's narration bar replaces the caption, and the
// shell drives d1 → d2 through `step` (its action button is the import), so the tabs hide too.
export default function OverMergeGuard({
  scene,
  embedded = false,
  step: controlledStep,
}: {
  scene: SyntheticScene;
  embedded?: boolean;
  step?: number;
}) {
  const [internalStep, setInternalStep] = useState(0);
  const step = controlledStep ?? internalStep;
  const date = scene.steps[step];
  const variants = scene.asOf[date]?.variants ?? [];
  const flagged = step === 1;

  return (
    <div className="panel">
      <div className="readout">
        as-of <b>{date}</b> · <span className="count-1">{variants.length} keys</span>{" "}
        {flagged ? "— a late barcode bridges them" : "— two disjoint identities"}
      </div>

      {!embedded && (
        <div className="stepper" role="tablist" aria-label="step">
          {scene.steps.map((s, i) => (
            <button
              key={s}
              className="step-btn"
              role="tab"
              aria-selected={step === i}
              onClick={() => setInternalStep(i)}
            >
              {i === 0 ? "d1" : "d2"} · {s}
            </button>
          ))}
        </div>
      )}

      <div className="guard-stage">
        {variants.map((v, i) => (
          <motion.div
            key={v.key}
            className="card"
            layout
            animate={flagged ? { x: i === 0 ? [0, 12, 0] : [0, -12, 0] } : { x: 0 }}
            transition={{ duration: 0.5, delay: flagged ? 0.6 : 0 }}
          >
            <div className="card-key">
              key <b>{v.key}</b>
            </div>
            <div className="chips">
              {v.codes.map((c) => (
                <span key={c} className={chipClass(c)}>
                  {c}
                </span>
              ))}
            </div>
          </motion.div>
        ))}

        <AnimatePresence>
          {flagged && (
            <motion.svg
              className="guard-edge"
              key="edge"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
            >
              <motion.line
                x1="20%"
                y1="50%"
                x2="80%"
                y2="50%"
                stroke="var(--flag)"
                strokeWidth="2"
                strokeDasharray="6 4"
                initial={{ pathLength: 0 }}
                animate={{ pathLength: 1 }}
                transition={{ duration: 0.6 }}
              />
            </motion.svg>
          )}
        </AnimatePresence>

        <AnimatePresence>
          {flagged && (
            <motion.div
              className="bridge-node"
              key="bridge"
              initial={{ opacity: 0, y: -10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.3 }}
            >
              bridge E
              <br />
              [cnk, gtin]
            </motion.div>
          )}
        </AnimatePresence>

        <AnimatePresence>
          {flagged && (
            <motion.div
              className="flag-badge"
              key="flag"
              initial={{ opacity: 0, scale: 0.6 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.6 }}
              transition={{ type: "spring", stiffness: 500, damping: 18, delay: 0.55 }}
            >
              ⚠ FLAG — merge proposal (gated)
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {!embedded && (
        <p className="caption">
          A late barcode bridges two <b>established</b> identities → the engine <b>flags a proposal</b>;
          it does not silently merge. Both keys <b>survive</b> (still {variants.length} at d2). It's the
          over-merge guard (gr-ose), now visible <i>temporally</i> — the same restraint the time machine
          shows when 422156 simply <i>becomes</i> one identity rather than being assumed so.
        </p>
      )}
    </div>
  );
}
