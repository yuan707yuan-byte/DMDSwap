import { Header } from './components/Header'
import { Toasts } from './components/Toasts'
import { IS_DEPLOYED, SOCIAL_LINKS } from './lib/config'
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
        {SOCIAL_LINKS.map((l) => (
          <a key={l.href} className="link" href={l.href} target="_blank" rel="noreferrer noopener">{l.label}</a>
        ))}
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
