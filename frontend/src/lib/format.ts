import { formatUnits, parseUnits, type Address } from 'viem'

/** Parses a user-typed amount. Extra decimals beyond the token's precision are rejected, not rounded. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '.')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  try {
    return parseUnits(s, decimals)
  } catch {
    return null
  }
}

/** Sanitizes keystrokes for amount inputs (digits and one decimal point). */
export function sanitizeAmountInput(raw: string): string {
  let s = raw.replace(/,/g, '.').replace(/[^\d.]/g, '')
  const i = s.indexOf('.')
  if (i !== -1) s = s.slice(0, i + 1) + s.slice(i + 1).replace(/\./g, '')
  if (s.startsWith('.')) s = '0' + s
  return s.slice(0, 40)
}

export function formatAmount(value: bigint, decimals: number, maxSignificant = 6): string {
  const raw = formatUnits(value, decimals)
  const [int, frac = ''] = raw.split('.')
  const intGrouped = Number(int) >= 1e21 ? int : BigInt(int).toLocaleString('en-US')
  if (int !== '0') {
    const keep = Math.max(0, maxSignificant - int.length)
    const f = frac.slice(0, keep).replace(/0+$/, '')
    return f ? `${intGrouped}.${f}` : intGrouped
  }
  if (!frac || /^0*$/.test(frac)) return '0'
  const firstNonZero = frac.search(/[1-9]/)
  if (firstNonZero > 8) return '< 0.00000001'
  return `0.${frac.slice(0, firstNonZero + maxSignificant).replace(/0+$/, '')}`
}

/** Plain decimal string (no grouping) for putting back into an input. */
export function toInputString(value: bigint, decimals: number): string {
  const s = formatUnits(value, decimals)
  return s.includes('.') ? s.replace(/0+$/, '').replace(/\.$/, '') : s
}

export function shortAddress(a: Address | string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

export function formatBps(bps: number): string {
  const pct = bps / 100
  return `${pct < 0.01 && bps > 0 ? '< 0.01' : pct.toFixed(pct < 1 ? 2 : 1)}%`
}
