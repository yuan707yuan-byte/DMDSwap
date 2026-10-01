import { getAddress, isAddress, type Address } from 'viem'
import { erc20Abi } from '../abi/generated'
import { publicClient } from './client'
import { ADDRESSES, CHAIN_ID } from './config'
import type { Token } from './types'

export const DMD: Token = { address: 'native', symbol: 'DMD', name: 'DMD Diamond', decimals: 18, source: 'native' }
export const WDMD: Token = { address: ADDRESSES.wdmd, symbol: 'WDMD', name: 'Wrapped DMD', decimals: 18, source: 'core' }
export const CORE_TOKENS: Token[] = [DMD, WDMD]
const RESERVED_SYMBOLS = new Set(['DMD', 'WDMD'])

export const tokenKey = (t: Token) => (t.address === 'native' ? 'native' : t.address.toLowerCase())
export const sameToken = (a: Token | null, b: Token | null) => !!a && !!b && tokenKey(a) === tokenKey(b)
export const isUnverified = (t: Token) => t.source === 'imported' || t.source === 'pool'

/** Strip control/unicode characters so a token can't spoof another via look-alike glyphs or huge names. */
function clean(text: string, max: number): string {
  const s = text.replace(/[^\x20-\x7E]/g, '').trim().slice(0, max)
  return s || '?'
}

export async function fetchTokenMeta(address: Address, source: Token['source'] = 'imported'): Promise<Token> {
  const read = <T,>(functionName: 'symbol' | 'name' | 'decimals') =>
    publicClient.readContract({ address, abi: erc20Abi, functionName }) as Promise<T>
  const [symbol, name, decimals] = await Promise.all([read<string>('symbol'), read<string>('name'), read<number>('decimals')])
  const d = Number(decimals)
  if (!Number.isInteger(d) || d < 0 || d > 36) throw new Error('This contract reports an invalid number of decimals.')
  let sym = clean(symbol, 12)
  if (RESERVED_SYMBOLS.has(sym.toUpperCase()) && address.toLowerCase() !== ADDRESSES.wdmd.toLowerCase()) sym = `${sym}?`
  return { address: getAddress(address), symbol: sym, name: clean(name, 40), decimals: d, source }
}

const KEY = `dmdswap.tokens.${CHAIN_ID}.v1`

export function loadImportedTokens(): Token[] {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? '[]') as unknown
    if (!Array.isArray(raw)) return []
    return raw
      .filter((t): t is Token =>
        !!t && typeof t === 'object' && isAddress((t as Token).address as string) &&
        typeof (t as Token).symbol === 'string' && Number.isInteger((t as Token).decimals))
      .map((t) => ({ ...t, symbol: clean(t.symbol, 13), name: clean(t.name, 40), source: 'imported' as const }))
  } catch {
    return []
  }
}

export function saveImportedTokens(list: Token[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(list.filter((t) => t.source === 'imported')))
  } catch {
    /* storage unavailable: tokens stay for this session only */
  }
}
