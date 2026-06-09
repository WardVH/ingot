import { describe, it, expect } from "vitest";
import { tickIndexAtOrBefore, lastDateAtOrBefore } from "./snap";

describe("tickIndexAtOrBefore", () => {
  it("maps the endpoints to first and last tick", () => {
    expect(tickIndexAtOrBefore(0, 5)).toBe(0);
    expect(tickIndexAtOrBefore(1, 5)).toBe(4);
  });

  it("snaps DOWN — a tick activates only once the handle passes it", () => {
    // 5 ticks at 0, .25, .5, .75, 1. Just before .5 is still tick 1; exactly .5 is tick 2.
    expect(tickIndexAtOrBefore(0.49, 5)).toBe(1);
    expect(tickIndexAtOrBefore(0.5, 5)).toBe(2);
  });

  it("clamps out-of-range fractions", () => {
    expect(tickIndexAtOrBefore(-2, 5)).toBe(0);
    expect(tickIndexAtOrBefore(99, 5)).toBe(4);
  });

  it("handles degenerate axes", () => {
    expect(tickIndexAtOrBefore(0.5, 0)).toBe(-1);
    expect(tickIndexAtOrBefore(0.5, 1)).toBe(0);
  });
});

describe("lastDateAtOrBefore", () => {
  const dates = ["2018-08-31", "2023-11-15", "2024-03-14", "2026-04-27"];

  it("returns the date itself when the cursor lands on a tick", () => {
    expect(lastDateAtOrBefore("2023-11-15", dates)).toBe("2023-11-15");
  });

  it("snaps back to the previous date when between ticks", () => {
    expect(lastDateAtOrBefore("2023-11-14", dates)).toBe("2018-08-31");
    expect(lastDateAtOrBefore("2025-01-01", dates)).toBe("2024-03-14");
  });

  it("returns null before the first date", () => {
    expect(lastDateAtOrBefore("2000-01-01", dates)).toBeNull();
  });

  it("returns the last date past the end", () => {
    expect(lastDateAtOrBefore("2030-01-01", dates)).toBe("2026-04-27");
  });
});
