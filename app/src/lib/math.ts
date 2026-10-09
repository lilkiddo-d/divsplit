/**
 * Dashboard math. All inputs are plain numbers (already scaled from wad).
 *
 * A P+D pair is one "unit": it redeems for `scale` stock tokens. Before expiry
 *   price(P) + price(D) = 1 unit,   price(D) = 1 - exp(-r * t)
 * where r is the market-implied continuous dividend yield and t the years to expiry.
 */

export const SECONDS_PER_YEAR = 365 * 24 * 3600;

export function yearsUntil(expiry: number, now: number = Date.now() / 1000): number {
  return Math.max(0, expiry - now) / SECONDS_PER_YEAR;
}

/** Continuous implied dividend yield from a D price expressed in units (0..1). */
export function impliedYieldFromDPrice(dPriceUnits: number, years: number): number {
  if (years <= 0 || dPriceUnits <= 0 || dPriceUnits >= 1) return 0;
  return -Math.log(1 - dPriceUnits) / years;
}

/** Same, from the D price in stablecoin and the unit price in stablecoin. */
export function impliedYieldFromPrices(dPriceStable: number, unitPriceStable: number, years: number): number {
  if (unitPriceStable <= 0) return 0;
  return impliedYieldFromDPrice(dPriceStable / unitPriceStable, years);
}

/** AMM state -> yield: the pool stores ln(1 + annual rate) as lnImpliedRate (wad). */
export function yieldFromLnRate(lnRateWad: bigint): number {
  return Number(lnRateWad) / 1e18;
}

/** Convert a continuous rate to an annual effective yield. */
export function toApy(continuous: number): number {
  return Math.exp(continuous) - 1;
}

export interface CashDividend {
  exDate: number; // unix seconds
  ratePerShare: number; // USD per underlying share
}

/**
 * Trailing-12-month historical yield. Token price already includes the ERC-8056 multiplier, so the per-share
 * price is tokenPrice / multiplier.
 */
export function historicalYield(dividends: CashDividend[], tokenPriceUsd: number, multiplier: number, now: number = Date.now() / 1000): number {
  if (tokenPriceUsd <= 0 || multiplier <= 0) return 0;
  const sharePrice = tokenPriceUsd / multiplier;
  const sum = dividends.filter((d) => d.exDate <= now && d.exDate > now - SECONDS_PER_YEAR).reduce((a, d) => a + d.ratePerShare, 0);
  return sum / sharePrice;
}

/** Positive spread = market prices more dividends than history suggests (D rich); negative = D cheap. */
export function yieldSpread(implied: number, historical: number): number {
  return implied - historical;
}

export function fmtPct(x: number, digits = 2): string {
  if (!Number.isFinite(x)) return "–";
  return `${(x * 100).toFixed(digits)}%`;
}

export function fmtUsd(x: number, digits = 2): string {
  if (!Number.isFinite(x)) return "–";
  return x.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function fmtDate(ts: number): string {
  return new Date(ts * 1000).toISOString().slice(0, 10);
}
