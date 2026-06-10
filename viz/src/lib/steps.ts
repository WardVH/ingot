// Story navigation: a position is (chapter, step); advancing overflows into the next chapter and
// underflows into the previous one, clamped at both ends of the story. Pure — tested in steps.test.ts.

export interface Position {
  chapter: number;
  step: number;
}

/** Move `delta` (+1/-1) steps, crossing chapter boundaries; clamps at the story's ends. */
export function advance(pos: Position, delta: 1 | -1, counts: number[]): Position {
  const step = pos.step + delta;
  if (step >= 0 && step < (counts[pos.chapter] ?? 0)) return { chapter: pos.chapter, step };
  if (delta > 0) {
    return pos.chapter + 1 < counts.length ? { chapter: pos.chapter + 1, step: 0 } : pos;
  }
  return pos.chapter > 0 ? { chapter: pos.chapter - 1, step: (counts[pos.chapter - 1] ?? 1) - 1 } : pos;
}

/** Jump to the first step of a chapter (clamped to the story). */
export function jumpTo(chapter: number, counts: number[]): Position {
  return { chapter: Math.max(0, Math.min(counts.length - 1, chapter)), step: 0 };
}

/** This position's 0-based index in the flattened story (for the progress readout). */
export function flatIndex(pos: Position, counts: number[]): number {
  return counts.slice(0, pos.chapter).reduce((s, n) => s + n, 0) + pos.step;
}

export function totalSteps(counts: number[]): number {
  return counts.reduce((s, n) => s + n, 0);
}
