import { useState } from 'react'
import { formatAmount, sanitizeAmountInput } from '../lib/format'
import { isUnverified } from '../lib/tokens'
import type { Token } from '../lib/types'
import { TokenIcon } from './Brand'
import { TokenPicker } from './TokenPicker'

export function AmountField(props: {
  label: string
  token: Token | null
  onToken: (t: Token) => void
  value: string
  onValue: (v: string) => void
  balance: bigint | null
  onMax?: () => void
  exclude?: Token | null
  loading?: boolean
  invalid?: boolean
}) {
  const { label, token, onToken, value, onValue, balance, onMax, exclude, loading, invalid } = props
  const [picking, setPicking] = useState(false)
  const id = `amt-${label.replace(/\s/g, '').toLowerCase()}`
  return (
    <div className={`field${invalid ? ' field-invalid' : ''}`}>
      <div className="field-top">
        <label htmlFor={id}>{label}</label>
        {token && balance !== null && (
          <span className="field-bal">
            Balance {formatAmount(balance, token.decimals)}
            {onMax && balance > 0n && <button className="max" onClick={onMax}>Max</button>}
          </span>
        )}
      </div>
      <div className="field-main">
        <input
          id={id}
          className={`amount${loading ? ' amount-loading' : ''}`}
          inputMode="decimal"
          autoComplete="off"
          spellCheck={false}
          placeholder="0"
          value={value}
          onChange={(e) => onValue(sanitizeAmountInput(e.target.value))}
        />
        <button className={`token-btn${token ? '' : ' token-btn-empty'}`} onClick={() => setPicking(true)}>
          {token ? <><TokenIcon token={token} size={22} /><span>{token.symbol}</span>{isUnverified(token) && <span className="unverified" title="Imported token: verify its address">!</span>}</> : 'Select token'}
          <svg width="10" height="6" viewBox="0 0 10 6" aria-hidden="true"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>
        </button>
      </div>
      {picking && <TokenPicker exclude={exclude} onClose={() => setPicking(false)} onPick={(t) => { onToken(t); setPicking(false) }} />}
    </div>
  )
}
