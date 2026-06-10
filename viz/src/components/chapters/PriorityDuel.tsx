import type { EngineScene } from "../../lib/story";
import { EngineStage } from "./shared";

// Chapter 3 — who wins? Per-dimension priority tiers rank the contradicting sources; the full
// ranking stays visible as provenance; a top-tier tie goes to the steward instead of a guess.
const FOCUS: Record<string, string> = {
  "marketplace-weight": "weight_g",
  "supplier-weight": "weight_g",
  "manufacturer-weight": "weight_g",
  "color-tie": "color",
  "steward-pick": "color",
};

export default function PriorityDuel({ scene, step }: { scene: EngineScene; step: number }) {
  const s = scene.steps[step];
  return (
    <div className="panel">
      <div className="readout">
        <b>{scene.label}</b> · as-of <b>{s.date}</b>
        <span className="tier-note">
          weight tiers: manufacturer ≻ supplier ≻ marketplace · colour: manufacturer = supplier (one tier)
        </span>
      </div>
      <EngineStage step={s} prevStep={scene.steps[step - 1]} focusField={FOCUS[s.id]} />
    </div>
  );
}
