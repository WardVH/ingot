// Mirrors the shape `demo_export.exs` writes to src/data/story.json.
// The browser reimplements NO engine logic — every snapshot below is precomputed by the engine.

export interface CandidateView {
  source: string;
  value: string | number;
}

export interface ClaimView {
  order: number;
  source: string;
  kind: "identity" | "attribute" | "media";
  date: string;
  // identity
  ref?: string;
  codes?: string[];
  // attribute
  code?: string;
  field?: string;
  value?: string | number;
  // media
  asset?: string;
  target?: string;
  uri?: string;
}

export interface AttributeView {
  field: string;
  value: string | number;
  winner: string | null; // a source, or "steward:<name>"
  status: "resolved" | "needs_review" | "resolved_by_steward";
  candidates: CandidateView[]; // the full ranking, best first
}

export interface MediaView {
  asset: string;
  source: string;
  uri: string;
}

export interface GoldenView {
  key: string;
  codes: string[];
  attributes: AttributeView[];
  media: MediaView[];
}

export type QueueItem =
  | { type: "attr"; key: string; field: string; candidates: CandidateView[] }
  | { type: "merge"; keys: string[] };

export type StoryEvent =
  | { date: string; type: "MINT" | "MEMBERS"; key: string; codes: string[] }
  | { date: string; type: "MERGE"; from: string[]; into: string }
  | { date: string; type: "SPLIT"; key: string; kept: string[]; into: { key: string; codes: string[] }[] }
  | { date: string; type: "FLAG"; keys: string[] }
  | { date: string; type: "DECISION"; subject: string; decision: string; by: string };

export interface StoryStep {
  id: string;
  date: string;
  log: ClaimView[]; // the full append-only claim log, as of this beat
  events: StoryEvent[]; // what THIS beat emitted
  golden: GoldenView[]; // the projection — derived, never stored
  queue: QueueItem[]; // the open steward queue
}

export interface EngineScene {
  label: string;
  steps: StoryStep[];
}

// The one hand-authored scene: destructive merging is what the engine refuses to do,
// so it cannot be engine-exported. The viz labels it an illustration.
export interface OldWayRecord {
  source: string | null;
  code?: string;
  codes?: string[];
  name: string;
  weight_g: number;
  image: string;
}

export interface OldWayStep {
  id: string;
  a?: OldWayRecord;
  b?: OldWayRecord;
  matchedOn?: string;
  merged?: OldWayRecord;
  lost?: string[];
}

export interface OldWayScene {
  label: string;
  steps: OldWayStep[];
}

export interface StoryData {
  oldWay: OldWayScene;
  claims: EngineScene;
  priority: EngineScene;
  mistake: EngineScene;
}
