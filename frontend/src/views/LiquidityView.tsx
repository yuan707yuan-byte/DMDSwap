import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { AmountField } from '../components/AmountField'
import { TokenIcon } from '../components/Brand'
import { useBalance } from '../hooks/useBalance'
import { usePoolTokens } from '../hooks/usePoolTokens'
import { ADDRESSES, IS_DEPLOYED } from '../lib/config'
import { wrapMode } from '../lib/dex'
import { formatAmount, formatBps, parseAmount, toInputString } from '../lib/format'
import { orderedReserves, planAddLiquidity, planRemoveLiquidity, poolFor, scanPools, type Pool } from '../lib/liquidity'
import { quote as quoteAmount } from '../lib/math'
import { DMD, tokenKey } from '../lib/tokens'
import { approvalSteps, deadlineFromChain } from '../lib/tx'
import type { Token } from '../lib/types'
import { useApp, type TxStep } from '../store'

export function LiquidityView() {
  const [sub, setSub] = useState<'add' | 'positions'>('add')
  return (
    <section className="gem-frame" aria-label="Liquidity">
      <div className="gem">
        <div className="card-head">
          <h1>Liquidity</h1>
          <div className="segmented small" role="tablist">
            <button role="tab" aria-selected={sub === 'add'} className={sub === 'add' ? 'on' : ''} onClick={() => setSub('add')}>Add</button>
            <button role="tab" aria-selected={sub === 'positions'} className={sub === 'positions' ? 'on' : ''} onClick={() => setSub('positions')}>Your positions</button>
          </div>
        </div>
        {sub === 'add' ? <AddLiquidity /> : <Positions />}
      </div>
    </section>
  )
}

function AddLiquidity() {
  const { account, wrongChain, settings, runTx, block, liquidityPrefill, refreshKey } = useApp()
  const [a, setA] = useState<Token | null>(liquidityPrefill?.[0] ?? DMD)
  const [b, setB] = useState<Token | null>(liquidityPrefill?.[1] ?? null)
  const [aStr, setAStr] = useState('')
  const [bStr, setBStr] = useState('')
  const [edited, setEdited] = useState<'a' | 'b'>('a')
  const [pool, setPool] = useState<Pool | null | undefined>(undefined)
  const balA = useBalance(a)
  const balB = useBalance(b)

  useEffect(() => {
    if (liquidityPrefill) { setA(liquidityPrefill[0]); setB(liquidityPrefill[1]) }
  }, [liquidityPrefill])

  useEffect(() => {
    if (!a || !b || !IS_DEPLOYED || wrapMode(a, b)) return setPool(null)
    let live = true
    poolFor(a, b, account ?? undefined).then((p) => live && setPool(p), () => live && setPool(null))
    return () => {
      live = false
    }
  }, [a, b, account, block?.number, refreshKey])

  const isNew = !pool || pool.totalSupply === 0n
  const [rA, rB] = pool && a && !isNew ? orderedReserves(pool, a) : [0n, 0n]

  // keep the pool ratio when the pool exists
  useEffect(() => {
    if (isNew || !a || !b) return
    if (edited === 'a') {
      const v = parseAmount(aStr, a.decimals)
      setBStr(v ? toInputString(quoteAmount(v, rA, rB), b.decimals) : '')
    } else {
      const v = parseAmount(bStr, b.decimals)
      setAStr(v ? toInputString(quoteAmount(v, rB, rA), a.decimals) : '')
    }
  }, [aStr, bStr, edited, rA, rB, isNew]) // eslint-disable-line react-hooks/exhaustive-deps

  const amtA = a ? parseAmount(aStr, a.decimals) : null
  const amtB = b ? parseAmount(bStr, b.decimals) : null
  const share = pool && !isNew && amtA ? Number((amtA * 10_000n * pool.totalSupply) / rA / (pool.totalSupply + (amtA * pool.totalSupply) / rA)) : isNew && amtA ? 10_000 : 0

  let blocker: string | null = null
  if (!IS_DEPLOYED) blocker = 'DMDSwap isn’t configured yet'
  else if (!account) blocker = 'Connect wallet'
  else if (wrongChain) blocker = 'Switch to DMD in your wallet'
  else if (!a || !b) blocker = 'Select two tokens'
  else if (wrapMode(a, b)) blocker = 'DMD and WDMD are the same asset'
  else if (!amtA || !amtB) blocker = 'Enter amounts'
  else if (balA !== null && amtA > balA) blocker = `Not enough ${a.symbol}`
  else if (balB !== null && amtB > balB) blocker = `Not enough ${b.symbol}`

  const submit = async () => {
    if (!a || !b || !amtA || !amtB || !account) return
    const deadline = await deadlineFromChain(settings.deadlineMin)
    const plan = planAddLiquidity({ a, b, amountA: amtA, amountB: amtB, isNewPool: isNew, slippageBps: settings.slippageBps, to: account, deadline })
    const steps: TxStep[] = []
    for (const ap of plan.approvals) {
      const sym = ap.token.toLowerCase() === (a.address === 'native' ? '' : a.address.toLowerCase()) ? a.symbol : b.symbol
      for (const call of await approvalSteps(ap.token, account, ADDRESSES.router, ap.amount, settings.unlimitedApproval)) steps.push({ label: `Approve ${sym}`, call })
    }
    const title = isNew ? `Create ${a.symbol}/${b.symbol} pool` : `Add ${a.symbol}/${b.symbol} liquidity`
    steps.push({ label: title, call: plan.call })
    if (await runTx(title, steps)) { setAStr(''); setBStr('') }
  }

  return (
    <>
      <AmountField label="Deposit" token={a} onToken={(t) => { if (b && tokenKey(t) === tokenKey(b)) setB(a); setA(t) }} value={aStr} onValue={(v) => { setEdited('a'); setAStr(v) }} balance={balA}
        onMax={() => a && balA !== null && (setEdited('a'), setAStr(toInputString(a.address === 'native' ? (balA > 5n * 10n ** 16n ? balA - 5n * 10n ** 16n : 0n) : balA, a.decimals)))} />
      <div className="plus" aria-hidden="true">+</div>
      <AmountField label="Deposit" token={b} onToken={(t) => { if (a && tokenKey(t) === tokenKey(a)) setA(b); setB(t) }} value={bStr} onValue={(v) => { setEdited('b'); setBStr(v) }} balance={balB} />
      {a && b && pool !== undefined && !wrapMode(a, b) && (
        isNew
          ? <p className="hint warn">You’re creating this pool. The amounts you deposit set its starting price, so deposit them at the current market rate or traders will profit from the difference.</p>
          : <dl className="details">
              <div><dt>Pool</dt><dd>{formatAmount(rA, a.decimals)} {a.symbol} + {formatAmount(rB, b.decimals)} {b.symbol}</dd></div>
              <div><dt>Your share after deposit</dt><dd>{formatBps(share)}</dd></div>
              <div><dt>You earn</dt><dd>{formatBps(15)} of every trade in this pool, added to your position automatically</dd></div>
            </dl>
      )}
      <button className="btn primary big" disabled={!!blocker} onClick={() => void submit()}>{blocker ?? (isNew ? 'Create pool' : 'Add liquidity')}</button>
    </>
  )
}

function Positions() {
  const { account, refreshKey, runTx, settings } = useApp()
  const [pools, setPools] = useState<Pool[] | null>(null)
  const mine = (pools ?? []).filter((p) => p.lpBalance > 0n)
  const meta = usePoolTokens(mine.flatMap((p) => [p.token0, p.token1]))

  useEffect(() => {
    if (!account || !IS_DEPLOYED) return setPools([])
    let live = true
    setPools(null)
    scanPools(account).then((p) => live && setPools(p), () => live && setPools([]))
    return () => {
      live = false
    }
  }, [account, refreshKey])

  if (!account) return <p className="empty">Connect your wallet to see your liquidity positions.</p>
  if (pools === null) return <p className="empty">Loading your positions…</p>
  if (!mine.length) return <p className="empty">You don’t have liquidity in any pool yet. Add some to start earning 0.15% of every trade in that pool.</p>
  return (
    <ul className="positions">
      {mine.map((p) => {
        const t0 = meta[p.token0.toLowerCase()]
        const t1 = meta[p.token1.toLowerCase()]
        return t0 && t1 ? <PositionRow key={p.pair} pool={p} t0={t0} t1={t1} onRemove={async (pct, native) => {
          const liquidity = pct === 100 ? p.lpBalance : (p.lpBalance * BigInt(pct)) / 100n
          const deadline = await deadlineFromChain(settings.deadlineMin)
          const plan = planRemoveLiquidity({ pool: p, a: t0, b: t1, liquidity, slippageBps: settings.slippageBps, to: account, deadline, receiveNative: native })
          const steps: TxStep[] = (await approvalSteps(p.pair as Address, account, ADDRESSES.router, liquidity, false)).map((call) => ({ label: 'Approve liquidity tokens', call }))
          const title = `Remove ${pct}% of ${t0.symbol}/${t1.symbol}`
          steps.push({ label: title, call: plan.call })
          await runTx(title, steps)
        }} /> : null
      })}
    </ul>
  )
}

function PositionRow({ pool, t0, t1, onRemove }: { pool: Pool; t0: Token; t1: Token; onRemove: (pct: number, native: boolean) => Promise<void> }) {
  const [pct, setPct] = useState(50)
  const [native, setNative] = useState(true)
  const [busy, setBusy] = useState(false)
  const hasW = [pool.token0, pool.token1].some((x) => x.toLowerCase() === ADDRESSES.wdmd.toLowerCase())
  const a0 = (pool.lpBalance * pool.reserve0) / pool.totalSupply
  const a1 = (pool.lpBalance * pool.reserve1) / pool.totalSupply
  const shareBps = Number((pool.lpBalance * 10_000n) / pool.totalSupply)
  return (
    <li className="position">
      <div className="position-head">
        <span className="pair-badges"><TokenIcon token={t0} /><TokenIcon token={t1} /></span>
        <strong>{t0.symbol}/{t1.symbol}</strong>
        <span className="muted">{formatBps(shareBps)} of pool</span>
      </div>
      <p className="muted">Your position: {formatAmount(a0, t0.decimals)} {t0.symbol} and {formatAmount(a1, t1.decimals)} {t1.symbol}</p>
      <div className="chips">
        {[25, 50, 75, 100].map((v) => <button key={v} className={pct === v ? 'on' : ''} onClick={() => setPct(v)}>{v}%</button>)}
      </div>
      {hasW && (
        <label className="check"><input type="checkbox" checked={native} onChange={(e) => setNative(e.target.checked)} /> Receive DMD instead of WDMD</label>
      )}
      <button className="btn ghost" disabled={busy} onClick={() => { setBusy(true); void onRemove(pct, native).finally(() => setBusy(false)) }}>
        {busy ? 'Check your wallet…' : `Remove ${pct}%`}
      </button>
    </li>
  )
}
