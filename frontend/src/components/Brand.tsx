import { useState } from 'react'
import type { Address } from 'viem'
import type { Token } from '../lib/types'

/** Original brilliant-cut mark for DMDSwap. */
export function Logo({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true" className="logo-mark">
      <path d="M20 14h24l12 14-24 26L8 28z" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinejoin="round" />
      <path d="M8 28h48M26 14l-5 14 11 26 11-26-5-14M20 14l6 14M44 14l-6 14" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" opacity=".55" />
    </svg>
  )
}

/** Deterministic faceted avatar: the same address always gets the same gem, so changes are visible. */
export function Avatar({ address, size = 22 }: { address: Address | string; size?: number }) {
  const h = (i: number) => Number.parseInt(address.slice(2 + i * 4, 6 + i * 4), 16) % 360
  const c = (i: number, l: number) => `hsl(${h(i)} 70% ${l}%)`
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" className="avatar">
      <path d="M6 4h12l5 6-11 12L1 10z" fill={c(0, 62)} />
      <path d="M1 10h22L12 22z" fill={c(1, 48)} />
      <path d="M6 4l3 6h6l3-6z" fill={c(2, 74)} />
      <path d="M9 10l3 12 3-12z" fill={c(3, 56)} />
    </svg>
  )
}

export function TokenBadge({ symbol, size = 26 }: { symbol: string; size?: number }) {
  const hue = [...symbol].reduce((a, ch) => (a * 31 + ch.charCodeAt(0)) % 360, 7)
  return (
    <span className="token-badge" style={{ width: size, height: size, background: `hsl(${hue} 45% 32%)` }} aria-hidden="true">
      {symbol.slice(0, 1)}
    </span>
  )
}

/** Token logo from public/tokens (same site only), falling back to the letter badge if missing or broken. */
export function TokenIcon({ token, size = 26 }: { token: Token; size?: number }) {
  const [failed, setFailed] = useState<string | null>(null)
  if (token.logo && failed !== token.logo) {
    return (
      <img className="token-logo" src={token.logo} alt="" width={size} height={size} loading="lazy" decoding="async"
        onError={() => setFailed(token.logo ?? null)} />
    )
  }
  return <TokenBadge symbol={token.symbol} size={size} />
}
