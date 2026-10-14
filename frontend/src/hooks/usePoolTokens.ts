import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { ADDRESSES } from '../lib/config'
import { fetchTokenMeta, WDMD } from '../lib/tokens'
import type { Token } from '../lib/types'
import { useApp } from '../store'

const cache = new Map<string, Token>()

/** Metadata for tokens found in pools (unknown ones are marked unverified). */
export function usePoolTokens(addresses: Address[]): Record<string, Token> {
  const { tokens } = useApp()
  const [map, setMap] = useState<Record<string, Token>>({})
  const key = [...new Set(addresses.map((a) => a.toLowerCase()))].sort().join(',')
  useEffect(() => {
    let live = true
    const list = key ? key.split(',') : []
    Promise.all(list.map(async (a) => {
      if (a === ADDRESSES.wdmd.toLowerCase()) return [a, WDMD] as const
      const known = tokens.find((t) => t.address !== 'native' && t.address.toLowerCase() === a)
      if (known) return [a, known] as const
      if (!cache.has(a)) {
        const meta = await fetchTokenMeta(a as Address, 'pool').catch(() => ({ address: a as Address, symbol: '?', name: 'Unknown token', decimals: 18, source: 'pool' as const }))
        cache.set(a, meta)
      }
      return [a, cache.get(a)!] as const
    })).then((rows) => live && setMap(Object.fromEntries(rows)))
    return () => {
      live = false
    }
  }, [key, tokens])
  return map
}
