import { test } from "node:test";
import assert from "node:assert/strict";
import { impliedYieldFromDPrice, impliedYieldFromPrices, historicalYield, yearsUntil, toApy, SECONDS_PER_YEAR } from "./math.ts";

test("implied yield inverts the D price formula", () => {
  const r = 0.03;
  const t = 0.25;
  const d = 1 - Math.exp(-r * t);
  assert.ok(Math.abs(impliedYieldFromDPrice(d, t) - r) < 1e-12);
  assert.ok(Math.abs(impliedYieldFromPrices(d * 250, 250, t) - r) < 1e-12);
});

test("degenerate inputs return zero", () => {
  assert.equal(impliedYieldFromDPrice(0.01, 0), 0);
  assert.equal(impliedYieldFromDPrice(0, 1), 0);
  assert.equal(impliedYieldFromPrices(1, 0, 1), 0);
});

test("historical yield uses per-share price", () => {
  const now = 1_800_000_000;
  const divs = [0.25, 0.25, 0.26, 0.26].map((r, i) => ({ exDate: now - (i + 1) * 80 * 86400, ratePerShare: r }));
  divs.push({ exDate: now - 2 * SECONDS_PER_YEAR, ratePerShare: 100 }); // outside window
  const y = historicalYield(divs, 201, 1.005, now);
  assert.ok(Math.abs(y - 1.02 / 200) < 1e-12);
});

test("years and apy helpers", () => {
  assert.equal(yearsUntil(100, 200), 0);
  assert.ok(Math.abs(yearsUntil(SECONDS_PER_YEAR, 0) - 1) < 1e-12);
  assert.ok(Math.abs(toApy(Math.log(1.05)) - 0.05) < 1e-12);
});
