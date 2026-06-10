import { AnimatePresence, motion } from "motion/react";
import type { OldWayRecord, OldWayScene } from "../../lib/story";

// Chapter 1 — the strawman the finale answers. Deliberately dull: flat gray cards, no provenance
// chips. Hand-authored data (see story.ts) — destructive merging is what the engine refuses to do.
function RecordCard({ record, dead }: { record: OldWayRecord; dead?: boolean }) {
  const codes = record.codes ?? (record.code ? [record.code] : []);
  return (
    <motion.div
      className={`oldway-card${dead ? " dead" : ""}`}
      layout
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, scale: 0.9 }}
      transition={{ duration: 0.3 }}
    >
      <div className="oldway-source">{record.source ?? "— (no source attribution)"}</div>
      <div className="oldway-name">{record.name}</div>
      <div className="oldway-fields">
        {codes.map((c) => (
          <span key={c} className="oldway-field">
            {c}
          </span>
        ))}
        <span className="oldway-field">weight {record.weight_g} g</span>
        <span className="oldway-field">image {record.image}</span>
      </div>
    </motion.div>
  );
}

export default function OldWay({ scene, step }: { scene: OldWayScene; step: number }) {
  const s = scene.steps[step];
  const matched = s.id === "match";
  const fused = s.merged != null;

  return (
    <div className="panel oldway">
      <div className="readout">
        <b>{scene.label}</b>
        <span className="illustration-badge">legacy behaviour — illustration, not our engine</span>
      </div>

      <div className="oldway-stage">
        <AnimatePresence mode="popLayout">
          {!fused && s.a && <RecordCard key="a" record={s.a} />}
          {matched && (
            <motion.div
              key="link"
              className="oldway-link"
              initial={{ opacity: 0, scaleX: 0 }}
              animate={{ opacity: 1, scaleX: 1 }}
              exit={{ opacity: 0 }}
            >
              matched on {s.matchedOn}
            </motion.div>
          )}
          {!fused && s.b && <RecordCard key="b" record={s.b} />}
          {fused && s.merged && <RecordCard key="merged" record={s.merged} dead />}
        </AnimatePresence>
      </div>

      <AnimatePresence>
        {s.lost && (
          <motion.div
            className="lost-list"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
          >
            <span className="lost-label">destroyed in place</span>
            {s.lost.map((l) => (
              <motion.s key={l} initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.3 }}>
                {l}
              </motion.s>
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
