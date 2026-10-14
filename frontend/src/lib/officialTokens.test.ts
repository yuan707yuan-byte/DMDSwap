import { describe, expect, it } from 'vitest'
import { parseOfficialList } from './officialTokens'

const good = { address: '0x1111111111111111111111111111111111111111', symbol: 'ABC', name: 'ABC Token', decimals: 18, logo: '/tokens/abc.png' }

describe('official token list validation', () => {
  it('accepts a valid entry and marks it official', () => {
    const r = parseOfficialList({ tokens: [good] })
    expect(r.errors).toEqual([])
    expect(r.tokens[0]).toMatchObject({ symbol: 'ABC', decimals: 18, source: 'official', logo: '/tokens/abc.png' })
  })
  it('rejects bad addresses, duplicates, reserved symbols and bad decimals', () => {
    const r = parseOfficialList({ tokens: [
      { ...good, address: '0x123' },
      good,
      { ...good, symbol: 'ABC', address: '0x2222222222222222222222222222222222222222' },
      { ...good, symbol: 'DMD', address: '0x3333333333333333333333333333333333333333' },
      { ...good, symbol: 'XYZ', decimals: 77, address: '0x4444444444444444444444444444444444444444' },
    ] })
    expect(r.tokens.map((t) => t.symbol)).toEqual(['ABC'])
    expect(r.errors.join('\n')).toMatch(/not a valid 0x address/)
    expect(r.errors.join('\n')).toMatch(/symbol is listed twice/)
    expect(r.errors.join('\n')).toMatch(/built in/)
    expect(r.errors.join('\n')).toMatch(/decimals/)
  })
  it('only allows logos hosted on this site', () => {
    for (const logo of ['https://evil.example/x.png', '/tokens/../x.png', 'tokens/x.png', '/tokens/x.gif', 'data:image/png;base64,AA']) {
      const r = parseOfficialList({ tokens: [{ ...good, logo }] })
      expect(r.tokens).toEqual([])
    }
    expect(parseOfficialList({ tokens: [{ ...good, logo: '' }] }).tokens[0].logo).toBeUndefined()
  })
  it('validates core logos for DMD and WDMD', () => {
    expect(parseOfficialList({ coreLogos: { DMD: '/tokens/dmd.svg' }, tokens: [] }).coreLogos.DMD).toBe('/tokens/dmd.svg')
    expect(parseOfficialList({ coreLogos: { DMD: 'https://x.y/z.png' }, tokens: [] }).errors.length).toBe(1)
  })
})
