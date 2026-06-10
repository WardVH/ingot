import type { EngineScene } from "../../lib/story";
import { EngineStage } from "./shared";

// Chapter 6 — the finale, paying off chapter 1: a steward-approved WRONG merge fuses two keys; the
// weight contradiction surfaces (the evidence was never destroyed); one recorded split re-partitions
// the keys and every attribute + image re-homes to its code. Nothing re-imported, nothing lost.
const FOCUS: Record<string, string> = {
  "wrong-merge": "weight_g",
  contradiction: "weight_g",
};

const PHASE: Record<string, string> = {
  "two-products": "two distinct products — two keys",
  "wrong-merge": "steward-approved merge (it will turn out wrong)",
  contradiction: "the contradiction is visible — both claims survived",
  split: "one recorded operation: split",
  healed: "re-homed by code — the log never changed",
};

export default function MistakeArc({ scene, step }: { scene: EngineScene; step: number }) {
  const s = scene.steps[step];
  return (
    <div className="panel">
      <div className="readout">
        <b>{scene.label}</b> · as-of <b>{s.date}</b>
        <span className={`phase-note${s.id === "contradiction" ? " hot" : ""}`}>{PHASE[s.id]}</span>
      </div>
      <EngineStage step={s} prevStep={scene.steps[step - 1]} focusField={FOCUS[s.id]} />
    </div>
  );
}
