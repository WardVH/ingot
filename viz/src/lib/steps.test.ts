import { describe, expect, it } from "vitest";
import { advance, flatIndex, jumpTo, totalSteps } from "./steps";
import data from "../data/story.json";
import type { StoryData } from "./story";

const COUNTS = [4, 3, 2]; // a 3-chapter story

describe("advance", () => {
  it("moves within a chapter", () => {
    expect(advance({ chapter: 0, step: 1 }, 1, COUNTS)).toEqual({ chapter: 0, step: 2 });
    expect(advance({ chapter: 0, step: 2 }, -1, COUNTS)).toEqual({ chapter: 0, step: 1 });
  });

  it("overflows into the next chapter's first step", () => {
    expect(advance({ chapter: 0, step: 3 }, 1, COUNTS)).toEqual({ chapter: 1, step: 0 });
  });

  it("underflows into the previous chapter's last step", () => {
    expect(advance({ chapter: 1, step: 0 }, -1, COUNTS)).toEqual({ chapter: 0, step: 3 });
  });

  it("clamps at both ends of the story", () => {
    expect(advance({ chapter: 0, step: 0 }, -1, COUNTS)).toEqual({ chapter: 0, step: 0 });
    expect(advance({ chapter: 2, step: 1 }, 1, COUNTS)).toEqual({ chapter: 2, step: 1 });
  });
});

describe("jumpTo", () => {
  it("jumps to a chapter's first step, clamped to the story", () => {
    expect(jumpTo(1, COUNTS)).toEqual({ chapter: 1, step: 0 });
    expect(jumpTo(99, COUNTS)).toEqual({ chapter: 2, step: 0 });
    expect(jumpTo(-1, COUNTS)).toEqual({ chapter: 0, step: 0 });
  });
});

describe("flatIndex / totalSteps", () => {
  it("flattens positions for the progress readout", () => {
    expect(flatIndex({ chapter: 0, step: 0 }, COUNTS)).toBe(0);
    expect(flatIndex({ chapter: 1, step: 2 }, COUNTS)).toBe(6);
    expect(flatIndex({ chapter: 2, step: 1 }, COUNTS)).toBe(8);
    expect(totalSteps(COUNTS)).toBe(9);
  });
});

// The committed story.json matches what the chapter components expect — a drifted export fails here.
describe("story.json schema", () => {
  const story = data as unknown as StoryData;

  it("has the four scenes with their story beats", () => {
    expect(story.oldWay.steps.map((s) => s.id)).toEqual(["two-records", "match", "merge", "import"]);
    expect(story.claims.steps.map((s) => s.id)).toEqual([
      "first-claim",
      "first-attribute",
      "second-source",
      "media",
    ]);
    expect(story.priority.steps.map((s) => s.id)).toEqual([
      "one-product",
      "marketplace-weight",
      "supplier-weight",
      "manufacturer-weight",
      "color-tie",
      "steward-pick",
    ]);
    expect(story.mistake.steps.map((s) => s.id)).toEqual([
      "two-products",
      "wrong-merge",
      "contradiction",
      "split",
      "healed",
    ]);
  });

  it("every engine step carries log, events, golden, and queue", () => {
    for (const scene of [story.claims, story.priority, story.mistake]) {
      for (const step of scene.steps) {
        expect(step.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(Array.isArray(step.log)).toBe(true);
        expect(Array.isArray(step.events)).toBe(true);
        expect(Array.isArray(step.golden)).toBe(true);
        expect(Array.isArray(step.queue)).toBe(true);
        expect(step.golden.length).toBeGreaterThan(0);
      }
    }
  });

  it("the mistake arc's pivotal beats are present in the data", () => {
    const byId = Object.fromEntries(story.mistake.steps.map((s) => [s.id, s]));
    expect(byId["two-products"].golden).toHaveLength(2);
    expect(byId["wrong-merge"].golden).toHaveLength(1);
    expect(byId["contradiction"].queue).toEqual([
      expect.objectContaining({ type: "attr", field: "weight_g" }),
    ]);
    expect(byId["healed"].golden).toHaveLength(2);
    expect(byId["healed"].queue).toEqual([]);
  });
});
