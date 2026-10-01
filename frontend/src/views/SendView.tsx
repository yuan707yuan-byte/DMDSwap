import { useState } from 'react'
import type { Abi } from 'viem'
import { erc20Abi, nameRouterAbi } from '../abi/generated'
import { AmountField } from '../components/AmountField'
import { RecipientField } from '../components/RecipientField'
import { useBalance } from '../hooks/useBalance'
import { useRecipient } from '../hooks/useRecipient'
import { ADDRESSES, IS_DEPLOYED, LIMITS } from '../lib/config'
import { formatAmount, parseAmount, toInputString } from '../lib/format'
import { resolveDmdName } from '../lib/resolve'
import { DMD } from '../lib/tokens'
import { approvalSteps } from '../lib/tx'
import type { Token } from '../lib/types'
import { useApp, type TxStep } from '../store'

export function SendView() {
  const { account, wrongChain, runTx, settings } = useApp()
  const [token, setToken] = useState<Token | null>(DMD)
  const [amtStr, setAmtStr] = useState('')
  const [error, setError] = useState<string | null>(null)
  const bal = useBalance(token)
  const r = useRecipient(false, [token])
  const amount = token ? parseAmount(amtStr, token.decimals) : null

  let blocker: string | null = null
  if (!account) blocker = 'Connect wallet'
  else if (wrongChain) blocker = 'Switch to DMD in your wallet'
  else if (!token) blocker = 'Select a token'
  else if (!amount) blocker = 'Enter an amount'
  else if (bal !== null && amount > bal) blocker = `Not enough ${token.symbol}`
  else if (r.status !== 'ok' || !r.resolved || r.resolved.mode === 'self') blocker = r.mode === 'name' ? 'Enter an active DMD Name' : 'Enter a recipient address'
  else if (r.resolved.mode === 'name' && !IS_DEPLOYED) blocker = 'Name payments need DMDSwap configured'

  const submit = async () => {
    setError(null)
    if (!token || !amount || !account || !r.resolved || r.resolved.mode === 'self') return
    const rc = r.resolved
    const steps: TxStep[] = []
    let title: string
    if (rc.mode === 'name') {
      const now = await resolveDmdName(rc.name)
      if (now?.toLowerCase() !== rc.address.toLowerCase()) return setError(`${rc.name}.dmd changed owner. Check the new address before sending.`)
      title = `Send ${formatAmount(amount, token.decimals)} ${token.symbol} to ${rc.name}.dmd`
      const abi = nameRouterAbi as Abi
      if (token.address === 'native') {
        steps.push({ label: title, call: { address: ADDRESSES.nameRouter, abi, functionName: 'sendDMDToName', args: [rc.name, rc.address], value: amount } })
      } else {
        for (const call of await approvalSteps(token.address, account, ADDRESSES.nameRouter, amount, settings.unlimitedApproval)) steps.push({ label: `Approve ${token.symbol}`, call })
        steps.push({ label: title, call: { address: ADDRESSES.nameRouter, abi, functionName: 'sendTokenToName', args: [token.address, amount, rc.name, rc.address] } })
      }
    } else {
      title = `Send ${formatAmount(amount, token.decimals)} ${token.symbol}`
      steps.push(token.address === 'native'
        ? { label: title, transfer: { to: rc.address, value: amount } }
        : { label: title, call: { address: token.address, abi: erc20Abi as Abi, functionName: 'transfer', args: [rc.address, amount] } })
    }
    if (await runTx(title, steps)) setAmtStr('')
  }

  return (
    <section className="gem-frame" aria-label="Send">
      <div className="gem">
        <div className="card-head"><h1>Send</h1></div>
        <AmountField label="Amount" token={token} onToken={setToken} value={amtStr} onValue={setAmtStr} balance={bal}
          onMax={() => token && bal !== null && setAmtStr(toInputString(token.address === 'native' ? (bal > LIMITS.nativeGasReserve ? bal - LIMITS.nativeGasReserve : 0n) : bal, token.decimals))} />
        <RecipientField r={r} allowSelf={false} />
        {error && <p className="hint bad">{error}</p>}
        <button className="btn primary big" disabled={!!blocker} onClick={() => void submit()}>
          {blocker ?? (r.resolved?.mode === 'name' ? `Send to ${r.resolved.name}.dmd` : 'Send')}
        </button>
      </div>
    </section>
  )
}
