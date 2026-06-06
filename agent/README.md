# ShieldRoute Agent

The AI routing layer for ShieldRoute. Given a swap and the target pool's state, it
scores the swap's MEV exposure and recommends an execution path: send it direct, route
it through a ShieldRoute batch, or split it across several batches.

This is the "should I protect this trade, and how" decision an autonomous Mantle trading
agent makes before every swap.

## The model

The score is built from explainable on-chain math, not a black box:

- **Sandwich loss (60% weight).** The exact slippage a swap pays on the constant-product
  curve versus the zero-impact spot price. This is the value a sandwich attacker
  extracts. Measured in basis points of the trade.
- **Depth (25%).** Trade size as a fraction of pool reserves. Thin pools amplify every
  attack.
- **Volatility (15%).** Recent pair volatility widens a searcher's edge.

Each component is a saturating curve, combined into a 0-100 score with a routing
recommendation. Every input's contribution is returned in the `breakdown`, so the
decision is auditable.

| Score | Level | Routing |
|---|---|---|
| 0-19 | low | direct (batching overhead not worth it) |
| 20-44 | elevated | batch |
| 45-74 | high | batch |
| 75-100 | severe | split (large) or batch |

## Use as a library

```ts
import { scoreSwap } from "shieldroute-agent";

const r = scoreSwap(
  { amountIn: 50_000, volatility: 0.03 },
  { reserveIn: 1_000_000, reserveOut: 1_000_000, feeBps: 30 },
);
// r.score, r.level, r.routing, r.reason, r.breakdown
```

## CLI

```bash
npm install
npm run score -- score --in 50000 --reserveIn 1000000 --reserveOut 1000000 --fee 30 --vol 0.03
# add --json for machine output
```

## Build and test

```bash
npm install
npm run typecheck
npm test
```

9 tests cover the AMM math, the monotonicity of sandwich loss in size and depth, the
routing bands, the volatility effect, bounds, and degenerate input.

## AI disclosure

Built with substantial help from Claude (Anthropic), which proposed the scoring model and
wrote the code and tests. The author reviewed the model and verified it (typecheck and
tests green). The scoring is deterministic and the formulae are documented in
`src/scorer.ts`.
