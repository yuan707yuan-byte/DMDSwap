import { useEffect, useState } from 'react'
import { AmountField } from '../components/AmountField'
import { Avatar } from '../components/Brand'
import { Modal } from '../components/Modal'
import { RecipientField } from '../components/RecipientField'
import { SettingsPanel } from '../components/Settings'
import { useBalance } from '../hooks/useBalance'
import { useDebounced } from '../hooks/useDebounced'
import { useRecipient } from '../hooks/useRecipient'
import { IS_DEPLOYED, LIMITS } from '../lib/config'
import { bestQuote, planSwap, planWrap, wrapMode, type Quote } from '../lib/dex'
import { formatAmount, formatBps, parseAmount, toInputString } from '../lib/format'
import { maxInWithSlippage, minOutWithSlippage } from '../lib/math'
import { resolveDmdName } from '../lib/resolve'
import { DMD, tokenKey } from '../lib/tokens'
import { approvalSteps, deadlineFromChain } from '../lib/tx'
import type { Recipient, Token } from '../lib/types'
import { useApp, type TxStep } from '../store'

export function SwapView() {
  const { account, wrongChain, settings, runTx, block, switchChain } = useApp()
  const [tokenIn, setTokenIn] = useState<Token | null>(DMD)
  const [tokenOut, setTokenOut] = useState<Token | null>(null)
  const [inStr, setInStr] = useState('')
  const [outStr, setOutStr] = useState('')
  const [edited, setEdited] = useState<'in' | 'out'>('in')
  const [quote, setQuote] = useState<Quote | null>(null)
  const [quoteState, setQuoteState] = useState<'idle' | 'loading' | 'none' | 'ok'>('idle')
  const [quoteBlock, setQuoteBlock] = useState<bigint | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  const [reviewing, setReviewing] = useState(false)
  const [turns, setTurns] = useState(0)
  const [inverted, setInverted] = useState(false)
  const balIn = useBalance(tokenIn)
  const balOut = useBalance(tokenOut)
  const r = useRecipient(true, [tokenIn, tokenOut])

  const wrap = tokenIn && tokenOut ? wrapMode(tokenIn, tokenOut) : null
  const typedToken = edited === 'in' ? tokenIn : tokenOut
  const typedStr = edited === 'in' ? inStr : outStr
  const typedAmount = typedToken ? parseAmount(typedStr, typedToken.decimals) : null
  const key = useDebounced(`${typedStr}|${edited}|${tokenIn ? tokenKey(tokenIn) : ''}|${tokenOut ? tokenKey(tokenOut) : ''}`, 250)

  useEffect(() => {
    const setOther = (v: string) => (edited === 'in' ? setOutStr(v) : setInStr(v))
    if (!tokenIn || !tokenOut || !typedAmount) {
      setQuote(null); setQuoteState('idle')
      if (!typedStr) setOther('')
      return
    }
    if (wrap) {
      setQuote(null); setQuoteState('ok'); setOther(typedStr)
      return
    }
    if (!IS_DEPLOYED) return
    let live = true
    setQuoteState((s) => (s === 'ok' ? 'ok' : 'loading'))
    bestQuote(edited === 'in' ? 'exactIn' : 'exactOut', typedAmount, tokenIn, tokenOut).then(
      (q) => {
        if (!live) return
        setQuote(q); setQuoteState(q ? 'ok' : 'none'); setQuoteBlock(block?.number ?? null)
        if (!q) return setOther('')
        setOther(edited === 'in' ? toInputString(q.amounts[q.amounts.length - 1], tokenOut.decimals) : toInputString(q.amounts[0], tokenIn.decimals))
      },
      () => live && setQuoteState('none'),
    )
    return () => {
      live = false
    }
    // requote on every new block: prices are always live
  }, [key, block?.number]) // eslint-disable-line react-hooks/exhaustive-deps

  const amountIn = wrap ? typedAmount : quote?.amounts[0] ?? null
  const amountOut = wrap ? typedAmount : quote ? quote.amounts[quote.amounts.length - 1] : null
  const pullMax = wrap ? typedAmount : quote ? (quote.kind === 'exactIn' ? quote.amounts[0] : maxInWithSlippage(quote.amounts[0], settings.slippageBps)) : null
  const insufficient = pullMax !== null && balIn !== null && pullMax > balIn

  const flip = () => {
    setTokenIn(tokenOut); setTokenOut(tokenIn)
    setInStr(outStr); setOutStr(inStr)
    setEdited(edited === 'in' ? 'out' : 'in')
    setTurns((t) => t + 1)
  }
  const pickIn = (t: Token) => { if (tokenOut && tokenKey(t) === tokenKey(tokenOut)) setTokenOut(tokenIn); setTokenIn(t) }
  const pickOut = (t: Token) => { if (tokenIn && tokenKey(t) === tokenKey(tokenIn)) setTokenIn(tokenOut); setTokenOut(t) }
  const max = () => {
    if (!tokenIn || balIn === null) return
    const v = tokenIn.address === 'native' ? (balIn > LIMITS.nativeGasReserve ? balIn - LIMITS.nativeGasReserve : 0n) : balIn
    setEdited('in'); setInStr(toInputString(v, tokenIn.decimals))
  }

  const sendingElsewhere = r.mode !== 'self'
  let blocker: string | null = null
  if (!IS_DEPLOYED) blocker = 'DMDSwap isn’t configured yet'
  else if (!account) blocker = 'Connect wallet'
  else if (wrongChain) blocker = 'Switch to DMD'
  else if (!tokenIn || !tokenOut) blocker = 'Select a token'
  else if (!typedStr) blocker = 'Enter an amount'
  else if (typedAmount === null) blocker = `Too many decimals for ${typedToken?.symbol}`
  else if (typedAmount === 0n) blocker = 'Enter an amount'
  else if (wrap && sendingElsewhere) blocker = 'Wrapping only goes to your own wallet'
  else if (!wrap && quoteState === 'none') blocker = 'No liquidity for this trade yet'
  else if (!wrap && quoteState !== 'ok') blocker = 'Fetching price…'
  else if (insufficient) blocker = `Not enough ${tokenIn.symbol}`
  else if (sendingElsewhere && r.status !== 'ok') blocker = r.mode === 'name' ? 'Enter an active DMD Name' : 'Enter a recipient address'
  else if (quote && quote.impactBps > LIMITS.impactBlockBps) blocker = 'Price impact too high'

  const cta = wrap ? (wrap === 'wrap' ? 'Wrap DMD' : 'Unwrap WDMD') : sendingElsewhere ? 'Review swap and send' : 'Review swap'

  return (
    <section className="gem-frame" aria-label="Swap">
      <div className="gem">
        <div className="card-head">
          <h1>Swap</h1>
          <button className="icon-btn" aria-label="Trade settings" aria-expanded={showSettings} onClick={() => setShowSettings((v) => !v)}>
            <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h10M18 7h2M4 17h2M10 17h10" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" /><circle cx="16" cy="7" r="2.2" fill="none" stroke="currentColor" strokeWidth="1.8" /><circle cx="8" cy="17" r="2.2" fill="none" stroke="currentColor" strokeWidth="1.8" /></svg>
            <span className="icon-btn-text">{formatBps(settings.slippageBps)}</span>
          </button>
        </div>
        {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}

        <AmountField label="You pay" token={tokenIn} onToken={pickIn} value={inStr} onValue={(v) => { setEdited('in'); setInStr(v) }}
          balance={balIn} onMax={max} exclude={null} loading={edited === 'out' && quoteState === 'loading'} invalid={insufficient} />
        <div className="flip-wrap">
          <button className="flip" style={{ transform: `rotate(${45 + turns * 180}deg)` }} onClick={flip} aria-label="Switch pay and receive tokens">
            <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" style={{ transform: 'rotate(-45deg)' }}><path d="M12 4v16M6 14l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
          </button>
        </div>
        <AmountField label="You receive" token={tokenOut} onToken={pickOut} value={outStr} onValue={(v) => { setEdited('out'); setOutStr(v) }}
          balance={balOut} loading={edited === 'in' && quoteState === 'loading'} />

        <RecipientField r={r} allowSelf />

        {quote && tokenIn && tokenOut && amountIn && amountOut && (
          <TradeDetails quote={quote} tokenIn={tokenIn} tokenOut={tokenOut} slippageBps={settings.slippageBps} inverted={inverted} onInvert={() => setInverted((v) => !v)} quoteBlock={quoteBlock} />
        )}
        {wrap && typedAmount ? <p className="hint">Wrapping is 1:1 with no fee.</p> : null}

        <button className="btn primary big" disabled={!!blocker && blocker !== 'Switch to DMD'}
          onClick={() => (blocker === 'Switch to DMD' ? void switchChain() : setReviewing(true))}>
          {blocker ?? cta}
        </button>
      </div>

      {reviewing && tokenIn && tokenOut && typedAmount && account && r.resolved && (
        <ReviewSwap
          tokenIn={tokenIn} tokenOut={tokenOut} quote={quote} wrap={wrap} typedAmount={typedAmount} recipient={r.resolved}
          onClose={() => setReviewing(false)}
          onDone={() => { setReviewing(false); setInStr(''); setOutStr(''); setQuote(null) }}
          run={async (steps, title) => runTx(title, steps)}
          settings={settings} account={account}
        />
      )}
    </section>
  )
}

function rate(amountIn: bigint, amountOut: bigint, decIn: number, decOut: number): bigint {
  return (amountOut * 10n ** BigInt(decIn) * 10n ** 18n) / (amountIn * 10n ** BigInt(decOut))
}

function TradeDetails({ quote, tokenIn, tokenOut, slippageBps, inverted, onInvert, quoteBlock }: {
  quote: Quote; tokenIn: Token; tokenOut: Token; slippageBps: number; inverted: boolean; onInvert: () => void; quoteBlock: bigint | null
}) {
  const aIn = quote.amounts[0]
  const aOut = quote.amounts[quote.amounts.length - 1]
  const impactClass = quote.impactBps > LIMITS.impactDangerBps ? 'bad' : quote.impactBps > LIMITS.impactWarnBps ? 'warn' : 'good'
  const route = [tokenIn.symbol, ...(quote.path.length === 3 ? ['WDMD'] : []), tokenOut.symbol]
  const lpBps = Number(quote.feeBps) * (10_000 - Number(quote.shareBps)) / 10_000
  const protoBps = Number(quote.feeBps) - lpBps
  return (
    <dl className="details">
      <div><dt>Rate</dt><dd><button className="linkish" onClick={onInvert}>
        {inverted
          ? `1 ${tokenOut.symbol} = ${formatAmount(rate(aOut, aIn, tokenOut.decimals, tokenIn.decimals), 18)} ${tokenIn.symbol}`
          : `1 ${tokenIn.symbol} = ${formatAmount(rate(aIn, aOut, tokenIn.decimals, tokenOut.decimals), 18)} ${tokenOut.symbol}`}
      </button></dd></div>
      <div><dt>Price impact</dt><dd className={impactClass}>{formatBps(quote.impactBps)}</dd></div>
      {quote.kind === 'exactIn'
        ? <div><dt>Minimum received</dt><dd>{formatAmount(minOutWithSlippage(aOut, slippageBps), tokenOut.decimals)} {tokenOut.symbol}</dd></div>
        : <div><dt>Maximum spent</dt><dd>{formatAmount(maxInWithSlippage(aIn, slippageBps), tokenIn.decimals)} {tokenIn.symbol}</dd></div>}
      <div><dt>Fee</dt><dd>{formatBps(Number(quote.feeBps))} ({formatBps(lpBps)} to liquidity providers, {formatBps(protoBps)} to DMDSwap)</dd></div>
      <div><dt>Route</dt><dd className="route">{route.map((s, i) => <span key={i}>{s}</span>)}</dd></div>
      {quoteBlock !== null && <div><dt>Price as of</dt><dd>Block {quoteBlock.toLocaleString('en-US')}</dd></div>}
      {quote.impactBps > LIMITS.impactWarnBps && quote.impactBps <= LIMITS.impactBlockBps && (
        <p className={`hint ${impactClass}`}>This trade moves the price by {formatBps(quote.impactBps)}. You’ll get noticeably less than the market rate.</p>
      )}
    </dl>
  )
}

function ReviewSwap(props: {
  tokenIn: Token; tokenOut: Token; quote: Quote | null; wrap: 'wrap' | 'unwrap' | null; typedAmount: bigint; recipient: Recipient
  onClose: () => void; onDone: () => void; run: (steps: TxStep[], title: string) => Promise<boolean>
  settings: { slippageBps: number; deadlineMin: number; unlimitedApproval: boolean }; account: `0x${string}`
}) {
  const { tokenIn, tokenOut, wrap, typedAmount, recipient, onClose, onDone, run, settings, account } = props
  const [quote, setQuote] = useState<Quote | null>(props.quote)
  const [priceMoved, setPriceMoved] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const aIn = wrap ? typedAmount : quote!.amounts[0]
  const aOut = wrap ? typedAmount : quote!.amounts[quote!.amounts.length - 1]
  const toLabel = recipient.mode === 'name' ? `${recipient.name}.dmd` : null

  const confirm = async () => {
    setBusy(true); setError(null)
    try {
      if (wrap) {
        const ok = await run([{ label: wrap === 'wrap' ? 'Wrap DMD' : 'Unwrap WDMD', call: planWrap(wrap, typedAmount) }], wrap === 'wrap' ? 'Wrap DMD' : 'Unwrap WDMD')
        if (ok) onDone()
        return
      }
      // 1) fresh price: never sign a quote that got worse while you were reading
      const fresh = await bestQuote(quote!.kind, typedAmount, tokenIn, tokenOut)
      if (!fresh) throw new Error('This trade no longer has enough liquidity.')
      const drift = BigInt(10_000 - LIMITS.quoteDriftBps)
      const worse = quote!.kind === 'exactIn'
        ? fresh.amounts[fresh.amounts.length - 1] * 10_000n < quote!.amounts[quote!.amounts.length - 1] * drift
        : fresh.amounts[0] * drift > quote!.amounts[0] * 10_000n
      if (worse && !priceMoved) {
        setQuote(fresh); setPriceMoved(true); setBusy(false)
        return
      }
      // 2) name still points to the address shown (the contract enforces this again on-chain)
      if (recipient.mode === 'name') {
        const now = await resolveDmdName(recipient.name)
        if (now?.toLowerCase() !== recipient.address.toLowerCase()) throw new Error(`${recipient.name}.dmd changed owner. Review the new address before sending.`)
      }
      const deadline = await deadlineFromChain(settings.deadlineMin)
      const plan = planSwap({ quote: fresh, tokenIn, tokenOut, recipient, account, slippageBps: settings.slippageBps, deadline })
      const steps: TxStep[] = []
      if (plan.spender && tokenIn.address !== 'native') {
        for (const call of await approvalSteps(tokenIn.address, account, plan.spender, plan.pullAmount, settings.unlimitedApproval)) {
          steps.push({ label: `Approve ${tokenIn.symbol}`, call })
        }
      }
      const title = toLabel ? `Swap ${tokenIn.symbol} and send to ${toLabel}` : `Swap ${tokenIn.symbol} for ${tokenOut.symbol}`
      steps.push({ label: title, call: plan.call })
      if (await run(steps, title)) onDone()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={wrap ? (wrap === 'wrap' ? 'Wrap DMD' : 'Unwrap WDMD') : 'Review swap'} onClose={onClose}>
      <div className="review">
        <div className="review-amt"><span>You pay</span><strong>{formatAmount(aIn, tokenIn.decimals, 10)} {tokenIn.symbol}</strong></div>
        <div className="review-amt"><span>{recipient.mode === 'self' ? 'You receive' : 'They receive'}</span><strong>{formatAmount(aOut, tokenOut.decimals, 10)} {tokenOut.symbol}</strong></div>
        {!wrap && quote && (
          <p className="hint">
            {quote.kind === 'exactIn'
              ? `If the price moves more than ${formatBps(settings.slippageBps)}, the swap reverts. You receive at least ${formatAmount(minOutWithSlippage(aOut, settings.slippageBps), tokenOut.decimals)} ${tokenOut.symbol}.`
              : `If the price moves more than ${formatBps(settings.slippageBps)}, the swap reverts. You pay at most ${formatAmount(maxInWithSlippage(aIn, settings.slippageBps), tokenIn.decimals)} ${tokenIn.symbol}.`}
          </p>
        )}
        {recipient.mode !== 'self' && (
          <div className="review-to">
            <span>Recipient</span>
            <div className="resolved">
              <Avatar address={recipient.address} size={36} />
              <div>
                {toLabel && <strong>{toLabel}</strong>}
                <code className="mono-addr">{recipient.address}</code>
              </div>
            </div>
            <p className="hint">Check the avatar and address. Payments can’t be reversed.</p>
          </div>
        )}
        {priceMoved && <p className="hint warn">The price changed while you were reviewing. The amounts above are updated. Confirm again to accept them.</p>}
        {error && <p className="hint bad">{error}</p>}
        <button className="btn primary big" disabled={busy} onClick={() => void confirm()}>
          {busy ? 'Check your wallet…' : priceMoved ? 'Accept new price and confirm' : recipient.mode === 'name' ? `Confirm and send to ${toLabel}` : 'Confirm swap'}
        </button>
      </div>
    </Modal>
  )
}
