// Exact BigInt mirror of DmdSwapLibrary.sol — same formulas, same rounding (see math.test.ts).
export const BPS = 10_000n

export function getAmountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint, feeBps: bigint): bigint {
  if (amountIn <= 0n || reserveIn <= 0n || reserveOut <= 0n) return 0n
  const withFee = amountIn * (BPS - feeBps)
  return (withFee * reserveOut) / (reserveIn * BPS + withFee)
}

export function getAmountIn(amountOut: bigint, reserveIn: bigint, reserveOut: bigint, feeBps: bigint): bigint | null {
  if (amountOut <= 0n || reserveIn <= 0n || reserveOut <= 0n || amountOut >= reserveOut) return null
  return (reserveIn * amountOut * BPS) / ((reserveOut - amountOut) * (BPS - feeBps)) + 1n
}

export function quote(amountA: bigint, reserveA: bigint, reserveB: bigint): bigint {
  if (amountA <= 0n || reserveA <= 0n || reserveB <= 0n) return 0n
  return (amountA * reserveB) / reserveA
}

/** Minimum accepted output for an exact-input trade (rounds down). */
export function minOutWithSlippage(amountOut: bigint, slippageBps: number): bigint {
  return (amountOut * (BPS - BigInt(slippageBps))) / BPS
}

/** Maximum accepted input for an exact-output trade (rounds up). */
export function maxInWithSlippage(amountIn: bigint, slippageBps: number): bigint {
  return (amountIn * (BPS + BigInt(slippageBps)) + BPS - 1n) / BPS
}

export type Hop = { amountIn: bigint; amountOut: bigint; reserveIn: bigint; reserveOut: bigint }

/** Price impact in bps, excluding the swap fee: compares each hop's output with the fee-adjusted mid-price output. */
export function priceImpactBps(hops: Hop[], feeBps: bigint): number {
  const ONE = 10n ** 18n
  let ratio = ONE
  for (const h of hops) {
    if (h.reserveIn === 0n || h.amountIn === 0n) return 10_000
    const ideal = (h.amountIn * (BPS - feeBps) * h.reserveOut) / (h.reserveIn * BPS)
    if (ideal === 0n) return 10_000
    ratio = (ratio * h.amountOut) / ideal
  }
  if (ratio >= ONE) return 0
  return Number(((ONE - ratio) * BPS) / ONE)
}
