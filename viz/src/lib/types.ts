// Mirrors the shape `temporal_export.exs` writes to src/data/temporal.json.
// The browser reimplements NO engine logic — it only reads these precomputed projections.

export interface AttributeView {
  field: string;
  value: string;
  status: string; // "resolved" | "needs_review" | "resolved_by_steward" | ...
}

export interface VariantView {
  key: string;
  product: number | null;
  cnk: string | null;
  codes: string[];
  attributes: AttributeView[];
}

export interface AsOfState {
  variants: VariantView[];
}

export interface ClaimView {
  date: string;
  kind: string;
  source: string;
  codes: string[];
}

export type TimelineEvent =
  | { date: string; type: "MINT" | "MEMBERS"; key: string; codes: string[] }
  | { date: string; type: "MERGE"; from: string[]; into: string }
  | { date: string; type: "SPLIT"; key: string; into: string[] }
  | { date: string; type: "FLAG"; subject: string[] | string };

export interface RealScene {
  label: string;
  dates: string[]; // distinct claim dates, sorted ascending (ISO yyyy-mm-dd)
  mintDate: string;
  claims: ClaimView[];
  timeline: TimelineEvent[];
  asOf: Record<string, AsOfState>;
}

export interface SyntheticScene {
  label: string;
  steps: string[]; // [d1, d2]
  timeline: TimelineEvent[];
  asOf: Record<string, AsOfState>;
}

export interface TemporalData {
  real: RealScene;
  synthetic: SyntheticScene;
}
