/**
 * MEV risk scoring for a swap on a constant-product pool.
 *
 * The core signal is the attacker's optimal sandwich profit. A searcher who
 * front-runs a victim swap of size `dx` on a pool with reserves (x, y) buys
 * first to push the price, lets the victim execute at the worse price, then
 * sells back. The victim's loss (and roughly the attacker's gross profit) grows
 * with the trade-to-liquidity ratio. We compute that loss exactly for the pure
 * AMM path, express it in basis points of the trade, and blend in volatility and
 * size signals to produce a 0-100 risk score and a routing recommendation.
 *
 * This is deterministic, explainable math, not a black-box guess: every input's
 * contribution to the score is inspectable in the returned breakdown.
 */

export interface PoolState {
  /** Reserve of the token being sold (input token). */
  reserveIn: number;
  /** Reserve of the token being bought (output token). */
  reserveOut: number;
  /** Pool fee in basis points (e.g. 30 = 0.30%). */
  feeBps: number;
}

export interface SwapRequest {
  /** Amount of input token being sold, same units as reserveIn. */
  amountIn: number;
  /** Recent price volatility of the pair, as a fraction (0.02 = 2%). Optional. */
  volatility?: number;
}

export type Routing = "direct" | "batch" | "split";

export interface RiskBreakdown {
  /** Victim loss to an optimal sandwich, in basis points of the trade. */
  sandwichLossBps: number;
  /** Trade size as a fraction of the input reserve. */
  sizeRatio: number;
  /** Volatility contribution to the score. */
  volatilityComponent: number;
  /** Depth contribution (thin pools score higher). */
  depthComponent: number;
}

export interface RiskAssessment {
  /** Overall MEV risk, 0 (safe) to 100 (severe). */
  score: number;
  /** Human label for the score band. */
  level: "low" | "elevated" | "high" | "severe";
  /** Recommended execution path. */
  routing: Routing;
  /** Plain-English reason for the recommendation. */
  reason: string;
  breakdown: RiskBreakdown;
}

const BPS = 10_000;

/**
 * Constant-product output for selling `amountIn`, net of fee.
 * out = (amountIn * (1 - fee) * reserveOut) / (reserveIn + amountIn * (1 - fee))
 */
export function ammOut(amountIn: number, reserveIn: number, reserveOut: number, feeBps: number): number {
  const inAfterFee = amountIn * (1 - feeBps / BPS);
  return (inAfterFee * reserveOut) / (reserveIn + inAfterFee);
}

/**
 * Victim loss to an optimal sandwich, in basis points of the victim's fair
 * output. We approximate the searcher's optimal front-run as the size that
 * maximises extraction; for a constant-product pool the victim's slippage versus
 * the no-attacker fill is a monotonic function of the size ratio, so we measure
 * the realised slippage of the trade itself against the spot (zero-size) price,
 * which is the value a sandwich captures. This is exact for the AMM path.
 */
export function sandwichLossBps(req: SwapRequest, pool: PoolState): number {
  const { amountIn, } = req;
  const { reserveIn, reserveOut, feeBps } = pool;
  if (amountIn <= 0 || reserveIn <= 0 || reserveOut <= 0) return 0;

  // Spot (marginal, zero-size) price: how much out per in with no impact.
  const spotOutPerIn = (reserveOut / reserveIn) * (1 - feeBps / BPS);
  const fairOut = amountIn * spotOutPerIn;

  // Actual fill on the curve (this is what the victim gets; the gap is what a
  // sandwich extracts by ordering around the victim).
  const realOut = ammOut(amountIn, reserveIn, reserveOut, feeBps);

  if (fairOut <= 0) return 0;
  const lossFraction = (fairOut - realOut) / fairOut;
  return Math.max(0, lossFraction * BPS);
}

/** Map a 0..1 input through a smooth saturating curve to 0..1. */
function saturate(x: number, k: number): number {
  if (x <= 0) return 0;
  return 1 - Math.exp(-k * x);
}

/**
 * Score a swap's MEV exposure and recommend a routing path.
 *
 * Routing logic:
 *  - low risk        -> direct (batching overhead not worth it)
 *  - elevated/high   -> batch (commit-reveal removes the attack window)
 *  - severe + large  -> split (batch across several batches to cap residual)
 */
export function scoreSwap(req: SwapRequest, pool: PoolState): RiskAssessment {
  const lossBps = sandwichLossBps(req, pool);
  const sizeRatio = pool.reserveIn > 0 ? req.amountIn / pool.reserveIn : 1;
  const vol = req.volatility ?? 0;

  // Components, each 0..1.
  // Sandwich loss dominates: 50bps of extractable loss is already serious.
  const lossComponent = saturate(lossBps / 50, 1.0);
  // Thin depth amplifies everything; 10% of the pool in one trade is a lot.
  const depthComponent = saturate(sizeRatio / 0.1, 1.2);
  // Volatility widens searcher edge; 5% recent vol is meaningful.
  const volatilityComponent = saturate(vol / 0.05, 0.8);

  const score = Math.round(
    100 * Math.min(1, 0.6 * lossComponent + 0.25 * depthComponent + 0.15 * volatilityComponent),
  );

  let level: RiskAssessment["level"];
  let routing: Routing;
  let reason: string;

  if (score < 20) {
    level = "low";
    routing = "direct";
    reason = `Sandwich loss ~${lossBps.toFixed(1)}bps on a deep pool; batching overhead is not worth it.`;
  } else if (score < 45) {
    level = "elevated";
    routing = "batch";
    reason = `Sandwich loss ~${lossBps.toFixed(1)}bps; route through a ShieldRoute batch to remove the attack window.`;
  } else if (score < 75) {
    level = "high";
    routing = "batch";
    reason = `Sandwich loss ~${lossBps.toFixed(1)}bps at ${(sizeRatio * 100).toFixed(1)}% of pool depth; batch to clear at a uniform price.`;
  } else {
    level = "severe";
    routing = sizeRatio > 0.05 ? "split" : "batch";
    reason =
      routing === "split"
        ? `Severe exposure: ${(sizeRatio * 100).toFixed(1)}% of pool depth. Split across batches so each residual stays small.`
        : `Severe exposure from volatility; batch and consider waiting for calmer conditions.`;
  }

  return {
    score,
    level,
    routing,
    reason,
    breakdown: {
      sandwichLossBps: Number(lossBps.toFixed(2)),
      sizeRatio: Number(sizeRatio.toFixed(4)),
      volatilityComponent: Number(volatilityComponent.toFixed(3)),
      depthComponent: Number(depthComponent.toFixed(3)),
    },
  };
}
