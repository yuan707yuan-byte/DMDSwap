import { describe, expect, it } from 'vitest'
import { getAmountIn, getAmountOut, maxInWithSlippage, minOutWithSlippage, priceImpactBps } from './math'
import { isValidDmdName, nameProblem, normalizeName } from './names'
import vectors from './vectors.json'

describe('swap math mirrors DmdSwapLibrary.sol', () => {
  it('matches 300 reference vectors (independent big-int implementation)', () => {
    for (const [a, ri, ro, f, o, oo, i] of vectors as [string, string, string, number, string, string, string][]) {
      expect(getAmountOut(BigInt(a), BigInt(ri), BigInt(ro), BigInt(f))).toBe(BigInt(o))
      expect(getAmountIn(BigInt(oo), BigInt(ri), BigInt(ro), BigInt(f))).toBe(BigInt(i))
    }
  })
  it('known value: 1e18 in, 1e24/1e24 pool, 0.30% fee', () => {
    expect(getAmountOut(10n ** 18n, 10n ** 24n, 10n ** 24n, 30n)).toBe(996999005991991025n)
  })
  it('exact-output never asks for less than needed', () => {
    const need = getAmountIn(10n ** 18n, 10n ** 24n, 3n * 10n ** 24n, 30n)!
    expect(getAmountOut(need, 10n ** 24n, 3n * 10n ** 24n, 30n)).toBeGreaterThanOrEqual(10n ** 18n)
    expect(getAmountOut(need - 1n, 10n ** 24n, 3n * 10n ** 24n, 30n)).toBeLessThan(10n ** 18n)
  })
  it('slippage bounds round in the user’s favour', () => {
    expect(minOutWithSlippage(10_000n, 50)).toBe(9_950n)
    expect(maxInWithSlippage(10_001n, 50)).toBe(10_052n) // 10051.005 rounded up
  })
  it('price impact is ~0 for tiny trades and large for big ones', () => {
    const r = 10n ** 24n
    const small = getAmountOut(10n ** 15n, r, r, 30n)
    expect(priceImpactBps([{ amountIn: 10n ** 15n, amountOut: small, reserveIn: r, reserveOut: r }], 30n)).toBe(0)
    const big = getAmountOut(r / 5n, r, r, 30n)
    expect(priceImpactBps([{ amountIn: r / 5n, amountOut: big, reserveIn: r, reserveOut: r }], 30n)).toBeGreaterThan(1500)
  })
})

describe('DMD Name rules mirror DMDRegistrarController.valid()', () => {
  const valid = ['ab', 'a1', 'a-b', 'a-b-c', '0x', '123', 'a2-z9', 'zz', 'x-1', '9-9', 'a'.repeat(63)]
  const invalid = ['a', '-ab', 'ab-', 'a--b', 'Ab', 'a_b', 'a.b', 'a b', '', 'äb', 'a'.repeat(64)]
  it.each(valid)('accepts %s', (n) => expect(isValidDmdName(n)).toBe(true))
  it.each(invalid)('rejects %s', (n) => expect(isValidDmdName(n)).toBe(false))
  it('normalizes case and the .dmd suffix but nothing else', () => {
    expect(normalizeName('  Alice.DMD ')).toBe('alice')
    expect(normalizeName('al1ce')).toBe('al1ce')
    expect(nameProblem('a--b')).toMatch(/two hyphens/)
  })
})
