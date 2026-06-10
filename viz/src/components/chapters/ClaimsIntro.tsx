import type { EngineScene } from "../../lib/story";
import { EngineStage } from "./shared";

// Chapter 2 — the model reset: sources assert code-anchored claims; the golden record on the right
// is a fold over the log on the left. Every snapshot is real engine output (demo_export.exs).
export default function ClaimsIntro({ scene, step }: { scene: EngineScene; step: number }) {
  return (
    <div className="panel">
      <div className="readout">
        <b>{scene.label}</b> · as-of <b>{scene.steps[step].date}</b>
      </div>
      <EngineStage step={scene.steps[step]} prevStep={scene.steps[step - 1]} />
    </div>
  );
}
