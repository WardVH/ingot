// Mirrors the shape `temporal_export.exs` writes to src/data/temporal.json.
// The browser reimplements NO engine logic — it only reads these precomputed projections.

export interface VariantView {
  key: string;
  cnk: string | null;
  codes: string[];
  sources: string[]; // the legacy source orgs whose listings resolve to this variant
}

// A legacy product (the legacy entity label) and the golden variants it resolves into, as-of a date.
export interface ProductGroup {
  product: number | null;
  variants: VariantView[];
}

export interface RealAsOf {
  products: ProductGroup[];
  proposals: string[][]; // standing over-merge proposals among the shown variants, e.g. [["SK_1","SK_3"]]
  retired: VariantView[]; // keys whose codes no source still claims (dead-barcode orphans)
}

export type TimelineEvent =
  | { date: string; type: "MINT" | "MEMBERS"; key: string; codes: string[] }
  | { date: string; type: "MERGE"; from: string[]; into: string }
  | { date: string; type: "SPLIT"; key: string; into: string[] }
  | { date: string; type: "FLAG"; subject: string[] | string };

export interface RealScene {
  label: string;
  dates: string[]; // distinct identity-event dates, sorted ascending (ISO yyyy-mm-dd)
  mintDate: string;
  timeline: TimelineEvent[];
  asOf: Record<string, RealAsOf>;
}

export interface SyntheticAsOf {
  variants: VariantView[];
}

export interface SyntheticScene {
  label: string;
  steps: string[]; // [d1, d2]
  timeline: TimelineEvent[];
  asOf: Record<string, SyntheticAsOf>;
}

export interface TemporalData {
  real: RealScene;
  synthetic: SyntheticScene;
}
