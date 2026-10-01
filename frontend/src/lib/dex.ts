import type { Abi, Address } from 'viem'
import { zeroAddress } from 'viem'
import { factoryAbi, nameRouterAbi, pairAbi, routerAbi, wdmdAbi } from '../abi/generated'
import { publicClient } from './client'
import { ADDRESSES } from './config'
import { getAmountIn, getAmountOut, maxInWithSlippage, minOutWithSlippage, priceImpactBps, type Hop } from './math'
import type { ContractCall } from './tx'
import type { Recipient, Token } from './types'

export const pathAddress = (t: Token): Address => (t.address === 'native' ? ADDRESSES.wdmd : t.address)
const lower = (a: Address) => a.toLowerCase()

export function wrapMode(a: Token, b: Token): 'wrap' | 'unwrap' | null {
  const w = lower(ADDRESSES.wdmd)
  if (a.address === 'native' && b.address !== 'native' && lower(b.address) === w) return 'wrap'
  if (b.address === 'native' && a.address !== 'native' && lower(a.address) === w) return 'unwrap'
  return null
}

export function candidatePaths(a: Token, b: Token): Address[][] {
  const A = pathAddress(a)
  const B = pathAddress(b)
  if (lower(A) === lower(B)) return []
  const paths: Address[][] = [[A, B]]
  const W = ADDRESSES.wdmd
  if (lower(A) !== lower(W) && lower(B) !== lower(W)) paths.push([A, W, B])
  return paths
}

// ── fee config (changes only via the 24h timelock; cached briefly)
let feeCache: { at: number; fee: bigint; share: bigint } | null = null
export async function feeConfig(): Promise<{ fee: bigint; share: bigint }> {
  if (feeCache && Date.now() - feeCache.at < 30_000) return feeCache
  const [fee, share] = await Promise.all([
    publicClient.readContract({ address: ADDRESSES.factory, abi: factoryAbi, functionName: 'swapFeeBps' }),
    publicClient.readContract({ address: ADDRESSES.factory, abi: factoryAbi, functionName: 'protocolFeeShareBps' }),
  ])
  feeCache = { at: Date.now(), fee: BigInt(fee), share: BigInt(share) }
  return feeCache
}

// ── pair lookup (pairs are permanent once created, so non-zero results are cached)
const pairCache = new Map<string, Address>()
export async function pairAddress(a: Address, b: Address): Promise<Address | null> {
  const key = [lower(a), lower(b)].sort().join(':')
  const cached = pairCache.get(key)
  if (cached) return cached
  const pair = await publicClient.readContract({ address: ADDRESSES.factory, abi: factoryAbi, functionName: 'getPair', args: [a, b] })
  if (pair === zeroAddress) return null
  pairCache.set(key, pair)
  return pair
}

export async function reservesFor(a: Address, b: Address): Promise<{ pair: Address; reserveA: bigint; reserveB: bigint } | null> {
  const pair = await pairAddress(a, b)
  if (!pair) return null
  const [r0, r1] = await publicClient.readContract({ address: pair, abi: pairAbi, functionName: 'getReserves' })
  const aIsToken0 = BigInt(a) < BigInt(b)
  return { pair, reserveA: aIsToken0 ? r0 : r1, reserveB: aIsToken0 ? r1 : r0 }
}

export type Quote = {
  kind: 'exactIn' | 'exactOut'
  path: Address[]
  amounts: bigint[]
  feeBps: bigint
  shareBps: bigint
  impactBps: number
}

async function quotePath(kind: Quote['kind'], amount: bigint, path: Address[], fee: bigint, share: bigint): Promise<Quote | null> {
  const reserves = await Promise.all(path.slice(0, -1).map((p, i) => reservesFor(p, path[i + 1])))
  if (reserves.some((r) => !r || r.reserveA === 0n || r.reserveB === 0n)) return null
  const amounts: bigint[] = new Array(path.length).fill(0n)
  if (kind === 'exactIn') {
    amounts[0] = amount
    for (let i = 0; i < path.length - 1; i++) amounts[i + 1] = getAmountOut(amounts[i], reserves[i]!.reserveA, reserves[i]!.reserveB, fee)
    if (amounts[path.length - 1] === 0n) return null
  } else {
    amounts[path.length - 1] = amount
    for (let i = path.length - 1; i > 0; i--) {
      const v = getAmountIn(amounts[i], reserves[i - 1]!.reserveA, reserves[i - 1]!.reserveB, fee)
      if (v === null) return null
      amounts[i - 1] = v
    }
  }
  const hops: Hop[] = reserves.map((r, i) => ({ amountIn: amounts[i], amountOut: amounts[i + 1], reserveIn: r!.reserveA, reserveOut: r!.reserveB }))
  return { kind, path, amounts, feeBps: fee, shareBps: share, impactBps: priceImpactBps(hops, fee) }
}

/** Best route among direct and via-WDMD, computed with the exact on-chain formulas at the latest block. */
export async function bestQuote(kind: Quote['kind'], amount: bigint, a: Token, b: Token): Promise<Quote | null> {
  if (amount <= 0n) return null
  const { fee, share } = await feeConfig()
  const quotes = (await Promise.all(candidatePaths(a, b).map((p) => quotePath(kind, amount, p, fee, share).catch(() => null))))
    .filter((q): q is Quote => q !== null)
  if (!quotes.length) return null
  return quotes.reduce((best, q) =>
    kind === 'exactIn'
      ? (q.amounts[q.amounts.length - 1] > best.amounts[best.amounts.length - 1] ? q : best)
      : (q.amounts[0] < best.amounts[0] ? q : best))
}

export type SwapPlan = { call: ContractCall; spender: Address | null; pullAmount: bigint; limit: bigint }

/**
 * Picks the exact contract function. Exact-input always uses the fee-on-transfer-safe variants (they verify
 * the amount actually received). Name recipients go through DmdNameRouter with the user-confirmed address.
 */
export function planSwap(p: {
  quote: Quote; tokenIn: Token; tokenOut: Token; recipient: Recipient; account: Address; slippageBps: number; deadline: bigint
}): SwapPlan {
  const { quote: q, tokenIn, tokenOut, recipient, account, slippageBps, deadline } = p
  const nativeIn = tokenIn.address === 'native'
  const nativeOut = tokenOut.address === 'native'
  const amountIn = q.amounts[0]
  const amountOut = q.amounts[q.amounts.length - 1]
  const toName = recipient.mode === 'name'
  const target = toName ? ADDRESSES.nameRouter : ADDRESSES.router
  const abi = (toName ? nameRouterAbi : routerAbi) as Abi
  const to = recipient.mode === 'self' ? account : recipient.address
  const nameArgs = toName ? [recipient.name, recipient.address] : [to]

  if (q.kind === 'exactIn') {
    const minOut = minOutWithSlippage(amountOut, slippageBps)
    if (minOut === 0n) throw new Error('The output is too small to protect with a minimum. Increase the amount.')
    if (nativeIn) {
      const fn = toName ? 'swapExactDMDForTokensToName' : 'swapExactDMDForTokensSupportingFeeOnTransferTokens'
      return { call: { address: target, abi, functionName: fn, args: [minOut, q.path, ...nameArgs, deadline], value: amountIn }, spender: null, pullAmount: 0n, limit: minOut }
    }
    const fn = nativeOut
      ? (toName ? 'swapExactTokensForDMDToName' : 'swapExactTokensForDMDSupportingFeeOnTransferTokens')
      : (toName ? 'swapExactTokensForTokensToName' : 'swapExactTokensForTokensSupportingFeeOnTransferTokens')
    return { call: { address: target, abi, functionName: fn, args: [amountIn, minOut, q.path, ...nameArgs, deadline] }, spender: target, pullAmount: amountIn, limit: minOut }
  }

  const maxIn = maxInWithSlippage(amountIn, slippageBps)
  if (nativeIn) {
    const fn = toName ? 'swapDMDForExactTokensToName' : 'swapDMDForExactTokens'
    return { call: { address: target, abi, functionName: fn, args: [amountOut, q.path, ...nameArgs, deadline], value: maxIn }, spender: null, pullAmount: 0n, limit: maxIn }
  }
  const fn = nativeOut
    ? (toName ? 'swapTokensForExactDMDToName' : 'swapTokensForExactDMD')
    : (toName ? 'swapTokensForExactTokensToName' : 'swapTokensForExactTokens')
  return { call: { address: target, abi, functionName: fn, args: [amountOut, maxIn, q.path, ...nameArgs, deadline] }, spender: target, pullAmount: maxIn, limit: maxIn }
}

export function planWrap(mode: 'wrap' | 'unwrap', amount: bigint): ContractCall {
  return mode === 'wrap'
    ? { address: ADDRESSES.wdmd, abi: wdmdAbi as Abi, functionName: 'deposit', args: [], value: amount }
    : { address: ADDRESSES.wdmd, abi: wdmdAbi as Abi, functionName: 'withdraw', args: [amount] }
}
