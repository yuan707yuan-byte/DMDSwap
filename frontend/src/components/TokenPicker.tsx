import { useEffect, useMemo, useState } from 'react'
import { getAddress, isAddress } from 'viem'
import { EXPLORER_URL } from '../lib/config'
import { formatAmount, shortAddress } from '../lib/format'
import { fetchTokenMeta, isUnverified, tokenKey } from '../lib/tokens'
import type { Token } from '../lib/types'
import { readBalance } from '../hooks/useBalance'
import { useApp } from '../store'
import { TokenIcon } from './Brand'
import { Modal } from './Modal'

export function TokenPicker({ onPick, onClose, exclude }: { onPick: (t: Token) => void; onClose: () => void; exclude?: Token | null }) {
  const { tokens, addToken, account, refreshKey } = useApp()
  const [q, setQ] = useState('')
  const [balances, setBalances] = useState<Record<string, bigint>>({})
  const [candidate, setCandidate] = useState<Token | null>(null)
  const [lookup, setLookup] = useState<'idle' | 'loading' | 'error'>('idle')
  const [ack, setAck] = useState(false)

  useEffect(() => {
    if (!account) return
    let live = true
    Promise.all(tokens.map(async (t) => [tokenKey(t), await readBalance(t, account).catch(() => 0n)] as const))
      .then((rows) => live && setBalances(Object.fromEntries(rows)))
    return () => {
      live = false
    }
  }, [tokens, account, refreshKey])

  const query = q.trim()
  const filtered = useMemo(() => {
    const s = query.toLowerCase()
    return tokens.filter((t) => !s || t.symbol.toLowerCase().includes(s) || t.name.toLowerCase().includes(s) || (t.address !== 'native' && t.address.toLowerCase() === s))
  }, [tokens, query])

  useEffect(() => {
    setCandidate(null)
    setAck(false)
    if (!isAddress(query, { strict: false }) || tokens.some((t) => t.address !== 'native' && t.address.toLowerCase() === query.toLowerCase())) return setLookup('idle')
    setLookup('loading')
    let live = true
    fetchTokenMeta(getAddress(query)).then(
      (t) => live && (setCandidate(t), setLookup('idle')),
      () => live && setLookup('error'),
    )
    return () => {
      live = false
    }
  }, [query, tokens])

  return (
    <Modal title="Select a token" onClose={onClose}>
      <input className="search" placeholder="Search by name or paste a token address" value={q} onChange={(e) => setQ(e.target.value)} spellCheck={false} autoComplete="off" />
      <ul className="token-list">
        {filtered.map((t) => {
          const disabled = !!exclude && tokenKey(exclude) === tokenKey(t)
          return (
            <li key={tokenKey(t)}>
              <button className="token-row" disabled={disabled} onClick={() => onPick(t)}>
                <TokenIcon token={t} />
                <span className="token-row-text">
                  <strong>{t.symbol}</strong>
                  <small>{t.name}{isUnverified(t) && t.address !== 'native' ? ` · ${shortAddress(t.address)}` : ''}</small>
                </span>
                <span className="token-row-bal">{balances[tokenKey(t)] !== undefined ? formatAmount(balances[tokenKey(t)], t.decimals) : ''}</span>
              </button>
            </li>
          )
        })}
      </ul>
      {lookup === 'loading' && <p className="hint">Reading token contract…</p>}
      {lookup === 'error' && <p className="hint bad">That address isn’t an ERC-20 token on DMD Diamond.</p>}
      {candidate && candidate.address !== 'native' && (
        <div className="import-box">
          <div className="token-row static">
            <TokenIcon token={candidate} />
            <span className="token-row-text">
              <strong>{candidate.symbol}</strong>
              <small>{candidate.name}</small>
            </span>
          </div>
          <p className="warn-text">
            Anyone can create a token with any name, including fake versions of real tokens. Only import tokens whose
            contract address you have checked yourself.
          </p>
          <a className="link" href={`${EXPLORER_URL}/token/${candidate.address}`} target="_blank" rel="noreferrer noopener">
            View {shortAddress(candidate.address)} on the DMD explorer
          </a>
          <label className="check">
            <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} />
            I understand and checked the contract address
          </label>
          <button className="btn primary" disabled={!ack} onClick={() => { addToken(candidate); onPick({ ...candidate, source: 'imported' }) }}>
            Import {candidate.symbol}
          </button>
        </div>
      )}
    </Modal>
  )
}
