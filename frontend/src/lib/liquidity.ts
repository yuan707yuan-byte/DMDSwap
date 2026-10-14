import type { Abi, Address } from 'viem'
import { factoryAbi, pairAbi, routerAbi } from '../abi/generated'
import { publicClient } from './client'
import { ADDRESSES, LIMITS } from './config'
import { pairAddress, pathAddress } from './dex'
import { minOutWithSlippage } from './math'
import type { ContractCall } from './tx'
import type { Token } from './types'

export type Pool = {
  pair: Address
  token0: Address
  token1: Address
  reserve0: bigint
  reserve1: bigint
  totalSupply: bigint
  lpBalance: bigint
}

export async function readPool(pair: Address, account?: Address): Promise<Pool> {
  const r = (fn: 'token0' | 'token1' | 'totalSupply') => publicClient.readContract({ address: pair, abi: pairAbi, functionName: fn })
  const [token0, token1, reserves, totalSupply, lpBalance] = await Promise.all([
    r('token0') as Promise<Address>,
    r('token1') as Promise<Address>,
    publicClient.readContract({ address: pair, abi: pairAbi, functionName: 'getReserves' }),
    r('totalSupply') as Promise<bigint>,
    account ? publicClient.readContract({ address: pair, abi: pairAbi, functionName: 'balanceOf', args: [account] }) : Promise.resolve(0n),
  ])
  return { pair, token0, token1, reserve0: reserves[0], reserve1: reserves[1], totalSupply, lpBalance }
}

export async function poolFor(a: Token, b: Token, account?: Address): Promise<Pool | null> {
  const pair = await pairAddress(pathAddress(a), pathAddress(b))
  return pair ? readPool(pair, account) : null
}

/** Reserves ordered as (a, b). */
export function orderedReserves(pool: Pool, a: Token): [bigint, bigint] {
  return pool.token0.toLowerCase() === pathAddress(a).toLowerCase() ? [pool.reserve0, pool.reserve1] : [pool.reserve1, pool.reserve0]
}

export async function scanPools(account?: Address): Promise<Pool[]> {
  const n = Number(await publicClient.readContract({ address: ADDRESSES.factory, abi: factoryAbi, functionName: 'allPairsLength' }))
  const count = Math.min(n, LIMITS.maxPoolsScanned)
  const pools: Pool[] = []
  for (let start = 0; start < count; start += 8) {
    const idx = Array.from({ length: Math.min(8, count - start) }, (_, i) => start + i)
    const batch = await Promise.all(idx.map(async (i) => {
      const pair = await publicClient.readContract({ address: ADDRESSES.factory, abi: factoryAbi, functionName: 'allPairs', args: [BigInt(i)] })
      return readPool(pair, account)
    }))
    pools.push(...batch)
  }
  return pools
}

export function planAddLiquidity(p: {
  a: Token; b: Token; amountA: bigint; amountB: bigint; isNewPool: boolean; slippageBps: number; to: Address; deadline: bigint
}): { call: ContractCall; approvals: { token: Address; amount: bigint }[] } {
  const { a, b, amountA, amountB, isNewPool, slippageBps, to, deadline } = p
  const minA = isNewPool ? amountA : minOutWithSlippage(amountA, slippageBps)
  const minB = isNewPool ? amountB : minOutWithSlippage(amountB, slippageBps)
  const abi = routerAbi as Abi
  if (a.address === 'native' || b.address === 'native') {
    const [token, amtToken, minToken, amtDMD, minDMD] =
      a.address === 'native' ? [b, amountB, minB, amountA, minA] : [a, amountA, minA, amountB, minB]
    const tokenAddr = token.address as Address
    return {
      call: { address: ADDRESSES.router, abi, functionName: 'addLiquidityDMD', args: [tokenAddr, amtToken, minToken, minDMD, to, deadline], value: amtDMD },
      approvals: [{ token: tokenAddr, amount: amtToken }],
    }
  }
  const A = a.address as Address
  const B = b.address as Address
  return {
    call: { address: ADDRESSES.router, abi, functionName: 'addLiquidity', args: [A, B, amountA, amountB, minA, minB, to, deadline] },
    approvals: [{ token: A, amount: amountA }, { token: B, amount: amountB }],
  }
}

/** Removal uses the fee-on-transfer-safe variant for DMD pairs (works for every token). */
export function planRemoveLiquidity(p: {
  pool: Pool; a: Token; b: Token; liquidity: bigint; slippageBps: number; to: Address; deadline: bigint; receiveNative: boolean
}): { call: ContractCall; expectedA: bigint; expectedB: bigint } {
  const { pool, a, b, liquidity, slippageBps, to, deadline, receiveNative } = p
  const [rA, rB] = orderedReserves(pool, a)
  const expectedA = (liquidity * rA) / pool.totalSupply
  const expectedB = (liquidity * rB) / pool.totalSupply
  const minA = minOutWithSlippage(expectedA, slippageBps)
  const minB = minOutWithSlippage(expectedB, slippageBps)
  const abi = routerAbi as Abi
  const wdmd = ADDRESSES.wdmd.toLowerCase()
  const aIsW = pathAddress(a).toLowerCase() === wdmd
  const bIsW = pathAddress(b).toLowerCase() === wdmd
  if (receiveNative && (aIsW || bIsW)) {
    const [token, minToken, minDMD] = aIsW ? [pathAddress(b), minB, minA] : [pathAddress(a), minA, minB]
    return {
      call: { address: ADDRESSES.router, abi, functionName: 'removeLiquidityDMDSupportingFeeOnTransferTokens', args: [token, liquidity, minToken, minDMD, to, deadline] },
      expectedA, expectedB,
    }
  }
  return {
    call: { address: ADDRESSES.router, abi, functionName: 'removeLiquidity', args: [pathAddress(a), pathAddress(b), liquidity, minA, minB, to, deadline] },
    expectedA, expectedB,
  }
}
