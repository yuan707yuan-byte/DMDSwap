import { Header } from './components/Header'
import { Toasts } from './components/Toasts'
import { ADDRESSES, EXPLORER_URL, IS_DEPLOYED } from './lib/config'
import { AppProvider, useApp } from './store'
import { LiquidityView } from './views/LiquidityView'
import { PoolsView } from './views/PoolsView'
import { SendView } from './views/SendView'
import { SwapView } from './views/SwapView'

function Shell() {
  const { tab, rpcDown } = useApp()
  return (
    <>
      <Header />
      <main className="main">
        {!IS_DEPLOYED && (
          <div className="banner">
            DMDSwap’s contract addresses aren’t set for this site yet. Add them as VITE_ environment variables in
            Vercel (or in src/deployment.json) and redeploy.
          </div>
        )}
        {rpcDown && <div className="banner">Can’t reach the DMD Diamond network right now. Prices and balances will update when it’s back.</div>}
        {tab === 'swap' && <SwapView />}
        {tab === 'liquidity' && <LiquidityView />}
        {tab === 'send' && <SendView />}
        {tab === 'pools' && <PoolsView />}
      </main>
      <footer className="footer">
        <span>Swaps cost 0.30%: half goes to liquidity providers, half to DMDSwap.</span>
        {IS_DEPLOYED && <a className="link" href={`${EXPLORER_URL}/address/${ADDRESSES.router}`} target="_blank" rel="noreferrer noopener">Verify the contracts on the DMD explorer</a>}
        {IS_DEPLOYED && <a className="link" href={`${EXPLORER_URL}/address/${ADDRESSES.timelock}`} target="_blank" rel="noreferrer noopener">Pending admin changes (24h timelock)</a>}
      </footer>
      <Toasts />
    </>
  )
}

export default function App() {
  return (
    <AppProvider>
      <Shell />
    </AppProvider>
  )
}
