import { getAddress, isAddress } from 'viem'
import raw from '../official-tokens.json'
import type { Token } from './types'

/**
 * The official token list lives in src/official-tokens.json and is bundled into the app (reviewed in git,
 * served from this site only — nothing is fetched from third parties). Logos live in public/tokens/.
 * Invalid entries are skipped and reported; `npm run build` refuses to build while any entry is invalid.
 */
export const LOGO_PATTERN = /^\/tokens\/[A-Za-z0-9._-]+\.(png|svg|webp|jpg|jpeg)$/
const PRINTABLE = /^[\x20-\x7E]+$/
const RESERVED = new Set(['DMD', 'WDMD'])

export type ParsedList = { tokens: Token[]; coreLogos: { DMD?: string; WDMD?: string }; errors: string[] }

export function parseOfficialList(file: unknown): ParsedList {
  const errors: string[] = []
  const tokens: Token[] = []
  const coreLogos: ParsedList['coreLogos'] = {}
  const f = (file ?? {}) as { coreLogos?: Record<string, unknown>; tokens?: unknown }
  for (const key of ['DMD', 'WDMD'] as const) {
    const v = f.coreLogos?.[key]
    if (typeof v === 'string' && v !== '') {
      if (LOGO_PATTERN.test(v)) coreLogos[key] = v
      else errors.push(`coreLogos.${key}: logo must look like /tokens/name.png (got "${v}")`)
    }
  }
  if (!Array.isArray(f.tokens)) return { tokens, coreLogos, errors: [...errors, '"tokens" must be a list'] }
  const seenAddr = new Set<string>()
  const seenSym = new Set<string>()
  f.tokens.forEach((entry, i) => {
    const t = (entry ?? {}) as Record<string, unknown>
    const where = `tokens[${i}]${typeof t.symbol === 'string' ? ` (${t.symbol})` : ''}`
    const problems: string[] = []
    const address = typeof t.address === 'string' ? t.address.trim() : ''
    if (!isAddress(address, { strict: false })) problems.push('address is not a valid 0x address')
    const symbol = typeof t.symbol === 'string' ? t.symbol.trim() : ''
    if (!symbol || symbol.length > 12 || !PRINTABLE.test(symbol)) problems.push('symbol must be 1-12 plain characters')
    if (RESERVED.has(symbol.toUpperCase())) problems.push('DMD and WDMD are built in; don’t list them')
    const name = typeof t.name === 'string' ? t.name.trim() : ''
    if (!name || name.length > 40 || !PRINTABLE.test(name)) problems.push('name must be 1-40 plain characters')
    const decimals = t.decimals
    if (typeof decimals !== 'number' || !Number.isInteger(decimals) || decimals < 0 || decimals > 36) problems.push('decimals must be a whole number 0-36')
    const logo = t.logo
    if (logo !== undefined && logo !== '' && (typeof logo !== 'string' || !LOGO_PATTERN.test(logo))) problems.push('logo must look like /tokens/name.png (files in public/tokens)')
    if (!problems.length) {
      const checksummed = getAddress(address)
      if (seenAddr.has(checksummed.toLowerCase())) problems.push('this address is listed twice')
      if (seenSym.has(symbol.toUpperCase())) problems.push('this symbol is listed twice')
      if (!problems.length) {
        seenAddr.add(checksummed.toLowerCase())
        seenSym.add(symbol.toUpperCase())
        tokens.push({
          address: checksummed, symbol, name, decimals: decimals as number, source: 'official',
          ...(typeof logo === 'string' && logo ? { logo } : {}),
        })
      }
    }
    for (const p of problems) errors.push(`${where}: ${p}`)
  })
  return { tokens, coreLogos, errors }
}

const parsed = parseOfficialList(raw)
if (parsed.errors.length) console.error('[DMDSwap] official-tokens.json problems:', parsed.errors)

export const OFFICIAL_TOKENS: Token[] = parsed.tokens
export const CORE_LOGOS = parsed.coreLogos
export const OFFICIAL_SYMBOLS = new Set(OFFICIAL_TOKENS.map((t) => t.symbol.toUpperCase()))
export const OFFICIAL_ADDRESSES = new Set(OFFICIAL_TOKENS.map((t) => (t.address as string).toLowerCase()))
