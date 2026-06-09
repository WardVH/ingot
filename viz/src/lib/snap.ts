// The only real runtime logic in the viz: snap a continuous scrubber position to a discrete date.
//
// The engine's golden_as_of only CHANGES on the distinct claim dates, so the scrubber is exact, not
// interpolated: a cursor between two ticks reads the state of the LAST date at or before it.

/**
 * The index of the last tick at or before a 0..1 scrubber `fraction`, for `count` evenly-spaced
 * ticks. floor() means a tick "activates" only once the handle passes it — dragging right reveals
 * dates as time advances. Returns -1 for an empty axis.
 */
export function tickIndexAtOrBefore(fraction: number, count: number): number {
  if (count <= 0) return -1;
  const f = Math.max(0, Math.min(1, fraction));
  // +epsilon so f === i/(count-1) lands ON tick i despite float drift.
  return Math.min(count - 1, Math.floor(f * (count - 1) + 1e-9));
}

/**
 * The last date at or before `cursor`, from `dates` sorted ascending. ISO yyyy-mm-dd strings sort
 * lexicographically == chronologically. Returns null when `cursor` precedes every date.
 */
export function lastDateAtOrBefore(cursor: string, dates: string[]): string | null {
  let result: string | null = null;
  for (const d of dates) {
    if (d <= cursor) result = d;
    else break;
  }
  return result;
}
