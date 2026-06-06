#!/usr/bin/env node
/**
 * shieldroute — score a swap's MEV exposure and get a routing recommendation.
 *
 * Usage:
 *   shieldroute score --in <amount> --reserveIn <r0> --reserveOut <r1> \
 *                     [--fee <bps>] [--vol <fraction>] [--json]
 *
 * Example:
 *   shieldroute score --in 50000 --reserveIn 1000000 --reserveOut 1000000 --fee 30 --vol 0.03
 */

import { scoreSwap, type PoolState, type SwapRequest } from "./scorer.js";

interface Args {
  cmd: string;
  in?: number;
  reserveIn?: number;
  reserveOut?: number;
  fee?: number;
  vol?: number;
  json?: boolean;
}

function parse(argv: string[]): Args {
  const a: Args = { cmd: argv[0] ?? "help" };
  for (let i = 1; i < argv.length; i++) {
    const k = argv[i];
    switch (k) {
      case "--in": a.in = Number(argv[++i]); break;
      case "--reserveIn": a.reserveIn = Number(argv[++i]); break;
      case "--reserveOut": a.reserveOut = Number(argv[++i]); break;
      case "--fee": a.fee = Number(argv[++i]); break;
      case "--vol": a.vol = Number(argv[++i]); break;
      case "--json": a.json = true; break;
    }
  }
  return a;
}

function help(): void {
  process.stdout.write(
    [
      "shieldroute — MEV risk scorer and routing advisor for Mantle swaps",
      "",
      "Usage:",
      "  shieldroute score --in <amount> --reserveIn <r0> --reserveOut <r1>",
      "                    [--fee <bps>] [--vol <fraction>] [--json]",
      "",
      "Example:",
      "  shieldroute score --in 50000 --reserveIn 1000000 --reserveOut 1000000 --fee 30 --vol 0.03",
      "",
    ].join("\n") + "\n",
  );
}

function main(argv: string[]): void {
  const a = parse(argv);
  if (a.cmd !== "score") {
    help();
    return;
  }
  if (a.in === undefined || a.reserveIn === undefined || a.reserveOut === undefined) {
    process.stderr.write("score: --in, --reserveIn and --reserveOut are required\n");
    process.exitCode = 1;
    return;
  }

  const pool: PoolState = { reserveIn: a.reserveIn, reserveOut: a.reserveOut, feeBps: a.fee ?? 30 };
  const req: SwapRequest = { amountIn: a.in, volatility: a.vol };
  const r = scoreSwap(req, pool);

  if (a.json) {
    process.stdout.write(JSON.stringify(r, null, 2) + "\n");
    return;
  }

  process.stdout.write(
    [
      `MEV risk:   ${r.score}/100  (${r.level})`,
      `Routing:    ${r.routing}`,
      `Sandwich:   ${r.breakdown.sandwichLossBps} bps`,
      `Size/depth: ${(r.breakdown.sizeRatio * 100).toFixed(2)}% of pool`,
      `Reason:     ${r.reason}`,
    ].join("\n") + "\n",
  );
}

main(process.argv.slice(2));
