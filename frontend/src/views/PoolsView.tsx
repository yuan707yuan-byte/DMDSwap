import { useEffect, useState } from 'react'
import { TokenIcon } from '../components/Brand'
import { usePoolTokens } from '../hooks/usePoolTokens'
import { ADDRESSES, EXPLORER_URL, IS_DEPLOYED } from '../lib/config'
import { formatAmount, formatBps, shortAddress } from '../lib/format'
import { scanPools, type Pool } from '../lib/liquidity'
import { DMD, isUnverified } from '../lib/tokens'
import type { Token } from '../lib/types'
import { useApp } from '../store'

export function PoolsView() {
  const { account, refreshKey, openLiquidity, block } = useApp()
  const [pools, setPools] = useState<Pool[] | null>(null)
  const meta = usePoolTokens((pools ?? []).flatMap((p) => [p.token0, p.token1]))
  const minute = block ? block.timestamp / 60n : 0n

  useEffect(() => {
    if (!IS_DEPLOYED) return setPools([])
    let live = true
    scanPools(account ?? undefined).then((p) => live && setPools(p), () => live && setPools([]))
    return () => {
      live = false
    }
  }, [account, refreshKey, minute])

  const asDmd = (t: Token) => (t.address !== 'native' && t.address.toLowerCase() === ADDRESSES.wdmd.toLowerCase() ? DMD : t)

  return (
    <section className="wide-panel" aria-label="Pools">
      <div className="panel-head">
        <h1>Pools</h1>
        <button className="btn primary" onClick={() => openLiquidity(DMD, DMD)}>Create a pool</button>
      </div>
      {pools === null ? <p className="empty">Loading pools…</p> : !pools.length ? (
        <p className="empty">No pools yet. Create the first one by adding liquidity for a token pair.</p>
      ) : (
        <div className="table-scroll">
          <table className="pools">
            <thead><tr><th scope="col">Pair</th><th scope="col">Liquidity</th><th scope="col">Your share</th><th scope="col"><span className="sr-only">Actions</span></th></tr></thead>
            <tbody>
              {pools.map((p) => {
                const t0 = meta[p.token0.toLowerCase()]
                const t1 = meta[p.token1.toLowerCase()]
                if (!t0 || !t1) return null
                const share = p.totalSupply > 0n ? Number((p.lpBalance * 10_000n) / p.totalSupply) : 0
                return (
                  <tr key={p.pair}>
                    <td>
                      <span className="pair-badges"><TokenIcon token={t0} size={22} /><TokenIcon token={t1} size={22} /></span>
                      <a className="pair-name" href={`${EXPLORER_URL}/address/${p.pair}`} target="_blank" rel="noreferrer noopener">{t0.symbol}/{t1.symbol}</a>
                      {(isUnverified(t0) || isUnverified(t1)) && <small className="unverified-note" title="Contains a token that isn’t on the DMDSwap default list">Unlisted token {shortAddress(isUnverified(t0) ? p.token0 : p.token1)}</small>}
                    </td>
                    <td className="num">{formatAmount(p.reserve0, t0.decimals)} {t0.symbol}<br />{formatAmount(p.reserve1, t1.decimals)} {t1.symbol}</td>
                    <td className="num">{share ? formatBps(share) : '—'}</td>
                    <td><button className="btn ghost" onClick={() => openLiquidity(asDmd(t0), asDmd(t1))}>Add liquidity</button></td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
