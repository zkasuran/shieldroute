import { test } from "node:test";
import assert from "node:assert/strict";
import { scoreSwap, sandwichLossBps, ammOut, type PoolState } from "../src/scorer.ts";

const deep: PoolState = { reserveIn: 1_000_000, reserveOut: 1_000_000, feeBps: 30 };
const thin: PoolState = { reserveIn: 10_000, reserveOut: 10_000, feeBps: 30 };

test("ammOut matches constant-product formula", () => {
  // selling 1000 into a 1:1 pool of 1e6 with 0.3% fee
  const out = ammOut(1000, 1_000_000, 1_000_000, 30);
  // fair (spot) would be ~997 after fee; real fill is slightly less
  assert.ok(out > 990 && out < 997, `unexpected out ${out}`);
});

test("sandwich loss grows with trade size", () => {
  const small = sandwichLossBps({ amountIn: 100 }, deep);
  const big = sandwichLossBps({ amountIn: 100_000 }, deep);
  assert.ok(big > small, "bigger trade must have higher sandwich loss");
  assert.ok(small >= 0);
});

test("sandwich loss grows as pool gets thinner", () => {
  const onDeep = sandwichLossBps({ amountIn: 1000 }, deep);
  const onThin = sandwichLossBps({ amountIn: 1000 }, thin);
  assert.ok(onThin > onDeep, "thin pool must expose more sandwich loss");
});

test("tiny trade on deep pool is low risk -> direct", () => {
  const r = scoreSwap({ amountIn: 50 }, deep);
  assert.equal(r.level, "low");
  assert.equal(r.routing, "direct");
  assert.ok(r.score < 20);
});

test("large trade on thin pool is high/severe -> batch or split", () => {
  const r = scoreSwap({ amountIn: 5_000 }, thin); // 50% of pool
  assert.ok(r.score >= 45, `expected high score, got ${r.score}`);
  assert.ok(r.routing === "batch" || r.routing === "split");
});

test("severe + very large trade recommends split", () => {
  const r = scoreSwap({ amountIn: 8_000 }, thin); // 80% of pool
  assert.equal(r.level, "severe");
  assert.equal(r.routing, "split");
});

test("volatility raises the score for the same trade", () => {
  const calm = scoreSwap({ amountIn: 20_000, volatility: 0 }, deep);
  const wild = scoreSwap({ amountIn: 20_000, volatility: 0.1 }, deep);
  assert.ok(wild.score >= calm.score, "higher volatility must not lower risk");
});

test("score is bounded 0..100 and breakdown is populated", () => {
  const r = scoreSwap({ amountIn: 200_000, volatility: 0.2 }, thin);
  assert.ok(r.score >= 0 && r.score <= 100);
  assert.ok(r.breakdown.sandwichLossBps >= 0);
  assert.ok(r.breakdown.sizeRatio >= 0);
  assert.ok(r.reason.length > 0);
});

test("zero or degenerate input does not throw", () => {
  assert.equal(sandwichLossBps({ amountIn: 0 }, deep), 0);
  const r = scoreSwap({ amountIn: 0 }, deep);
  assert.equal(r.routing, "direct");
});
