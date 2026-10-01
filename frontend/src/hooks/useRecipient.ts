import { useEffect, useState } from 'react'
import { getAddress, isAddress, type Address } from 'viem'
import { publicClient } from '../lib/client'
import { IS_DEPLOYED, PROTOCOL_ADDRESSES } from '../lib/config'
import { isValidDmdName, nameProblem, normalizeName } from '../lib/names'
import { resolveDmdName } from '../lib/resolve'
import type { Recipient, RecipientMode, Token } from '../lib/types'
import { useApp } from '../store'
import { useDebounced } from './useDebounced'

export type RecipientState = {
  mode: RecipientMode
  setMode: (m: RecipientMode) => void
  input: string
  setInput: (s: string) => void
  status: 'idle' | 'checking' | 'ok' | 'error'
  message: string | null
  isContract: boolean
  normalizedName: string
  resolved: Recipient | null
}

/** Address / DMD Name recipient with live on-chain resolution and footgun checks. */
export function useRecipient(allowSelf: boolean, tokens: (Token | null)[]): RecipientState {
  const { account, block } = useApp()
  const [mode, setMode] = useState<RecipientMode>(allowSelf ? 'self' : 'name')
  const [input, setInput] = useState('')
  const [status, setStatus] = useState<RecipientState['status']>('idle')
  const [message, setMessage] = useState<string | null>(null)
  const [isContract, setIsContract] = useState(false)
  const [resolved, setResolved] = useState<Recipient | null>(null)
  const debounced = useDebounced(input, 300)
  const normalizedName = normalizeName(debounced)
  const tokenAddrs = tokens.map((t) => (t && t.address !== 'native' ? t.address.toLowerCase() : '')).join(',')
  const blockNo = block?.number

  useEffect(() => {
    let live = true
    const done = (s: RecipientState['status'], m: string | null, r: Recipient | null, c = false) => {
      if (!live) return
      setStatus(s); setMessage(m); setResolved(r); setIsContract(c)
    }
    const blocked = (a: Address) =>
      PROTOCOL_ADDRESSES.has(a.toLowerCase()) || tokenAddrs.split(',').includes(a.toLowerCase())
    if (mode === 'self') {
      done(account ? 'ok' : 'idle', null, account ? { mode: 'self' } : null)
    } else if (mode === 'address') {
      const s = debounced.trim()
      if (!s) done('idle', null, null)
      else if (!isAddress(s, { strict: true })) done('error', 'That isn’t a valid address. Check for typos or a wrong checksum.', null)
      else {
        const a = getAddress(s)
        if (blocked(a)) done('error', 'That’s a DMDSwap or token contract. Tokens sent there are lost.', null)
        else {
          done('checking', null, null)
          publicClient.getCode({ address: a }).then(
            (code) => done('ok', null, { mode: 'address', address: a }, !!code && code !== '0x'),
            () => done('ok', null, { mode: 'address', address: a }),
          )
        }
      }
    } else {
      if (!normalizedName) done('idle', null, null)
      else if (!isValidDmdName(normalizedName)) done('error', nameProblem(normalizedName), null)
      else if (!IS_DEPLOYED) done('error', 'Name payments are available once DMDSwap is configured.', null)
      else {
        setStatus((s) => (s === 'ok' ? s : 'checking'))
        resolveDmdName(normalizedName).then(
          (a) => a
            ? done('ok', null, { mode: 'name', name: normalizedName, address: a })
            : done('error', `${normalizedName}.dmd isn’t an active DMD Name. It may be unregistered, inactive, expired or blocked.`, null),
          () => done('error', 'Couldn’t reach the DMD network to look up this name.', null),
        )
      }
    }
    return () => {
      live = false
    }
    // re-resolve names every block so the shown address is always current
  }, [mode, debounced, normalizedName, account, tokenAddrs, mode === 'name' ? blockNo : 0])

  return { mode, setMode, input, setInput, status, message, isContract, normalizedName, resolved }
}
