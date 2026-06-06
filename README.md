# ShieldRoute

MEV-protected swap execution for Mantle. Trading agents lose value to sandwiching
and front-running on every public swap. ShieldRoute removes the attack window: orders
are submitted as hidden commitments, batched, then revealed and settled together at a
single uniform clearing price. No order's direction, size or price is visible until the
batch closes, and every order in a batch clears at the same price, so a searcher has
nothing to front-run or sandwich.

Built for the Mantle Turing Test Hackathon 2026 (AI DevTools track). It is
infrastructure the other trading agents on Mantle plug into, not another trading bot.

## Why this matters on Mantle

Mantle's hackathon has dozens of autonomous AI trading and treasury agents. Every one
of them swaps on public DEXes and leaks value to MEV on each trade. ShieldRoute is the
execution layer they route through to stop that leak. It makes the whole agent economy
on Mantle cheaper and safer to operate in.

## How it works

A batch has three phases on fixed timers:

1. **Commit.** A trader submits `commit(hash)` where the hash binds their order
   (direction, amount, min-out) to their address and a secret salt. Nothing about the
   order is visible on-chain.
2. **Reveal.** After the commit window, the trader calls
   `reveal(zeroForOne, amountIn, minOut, salt)`. The contract checks the hash and
   escrows the input tokens. Reveals carry no ordering advantage: every order in the
   batch clears at one price regardless of reveal order.
3. **Settle.** After the reveal window, `settle()` nets all revealed flow (offsetting
   buys and sells cancel), prices only the net residual against the bound pool, and
   assigns every order its fill at that single clearing price. Each order's `minOut`
   slippage bound is enforced. Traders then `claim(batchId)` their output.

The key property: **internalised, offsetting flow pays zero pool slippage.** If one
agent sells token0 and another sells token1 in the same batch, they clear against each
other at spot with no impact for a searcher to capture. This is proved in
`test_offsetting_flow_clears_at_spot_no_sandwich_loss`.

## Architecture

```
src/
  ShieldRouter.sol              core batch commit-reveal-settle-claim contract
  interfaces/
    IERC20.sol                  minimal ERC20
    IBatchPool.sol              pricing source for the net batch residual
  mocks/
    MockERC20.sol               test/demo token
    MockConstantProductPool.sol x*y=k pricing for the residual (test/demo)
script/
  Deploy.s.sol                  deploys router + demo pair + pool to Mantle Sepolia
test/
  ShieldRouter.t.sol            9 tests, full lifecycle + MEV-protection proof
```

`ShieldRouter` settles against any `IBatchPool`. The mock constant-product pool is for
tests and the demo; in production this is an adapter over a real Mantle DEX.

## Build and test

Requires Foundry. Mantle-specific settings are pinned in `foundry.toml`
(`solc 0.8.23`, `evm_version = "shanghai"`) because Mantle's op-geth does not accept the
newer Cancun `MCOPY` opcode.

```bash
forge build
forge test -vv
```

All 9 tests pass. The suite covers the commit/reveal/settle/claim lifecycle, the
offsetting-flow zero-slippage property, salt and phase enforcement, double-commit
rejection, batch rollover, and the slippage bound.

## Deploy to Mantle Sepolia

Mantle requires the `--legacy` flag (it uses legacy transactions, not EIP-1559).

```bash
export PRIVATE_KEY=0x...   # a funded Mantle Sepolia key, never commit this
forge script script/Deploy.s.sol:Deploy --rpc-url mantle_sepolia --broadcast --legacy
```

Network details (verified against docs.mantle.xyz and the live RPC):

| | Mantle Sepolia |
|---|---|
| Chain ID | 5003 |
| RPC | https://rpc.sepolia.mantle.xyz |
| Explorer | https://sepolia.mantlescan.xyz/ |
| Faucet | https://faucet.sepolia.mantle.xyz/ |
| Gas token | MNT |

### Deployed contract addresses

Filled in after the human runs the deploy:

- ShieldRouter: `TBD`
- Demo token0 / token1: `TBD` / `TBD`
- Demo pool: `TBD`

## Scope and honesty

This is an MVP. The commit-reveal batch and the uniform-clearing-price settlement are
real and tested. The pool is a mock constant-product curve so the batch has something to
price the residual against in tests and the demo; a production deployment swaps in an
adapter over a live Mantle DEX. The AI risk-scoring layer (predict per-trade MEV
exposure and choose batch vs direct routing) is the next milestone and is not in this
contract.

## AI disclosure

Built with substantial help from Claude (Anthropic), which proposed the batch
commit-reveal design and wrote the contract and tests. The author reviewed the design
and verified it: `forge build` and `forge test` are green and the network parameters
were checked against the live Mantle docs and RPC. The author can explain the
batch-auction mechanism and every design choice.
