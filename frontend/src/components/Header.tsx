import { useState } from 'react'
import { EXPLORER_URL } from '../lib/config'
import { shortAddress } from '../lib/format'
import { useApp, type Tab } from '../store'
import { Avatar, Logo } from './Brand'
import { Modal } from './Modal'

const TABS: [Tab, string][] = [['swap', 'Swap'], ['liquidity', 'Liquidity'], ['send', 'Send'], ['pools', 'Pools']]

export function Header() {
  const { tab, setTab, block, rpcDown } = useApp()
  return (
    <header className="topbar">
      <div className="brand">
        <Logo />
        <span className="wordmark">DMDSwap</span>
      </div>
      <nav className="tabs" aria-label="Main">
        {TABS.map(([id, label]) => (
          <button key={id} className={tab === id ? 'on' : ''} aria-current={tab === id ? 'page' : undefined} onClick={() => setTab(id)}>{label}</button>
        ))}
      </nav>
      <div className="topbar-right">
        <span className={`live${rpcDown ? ' live-down' : ''}`} title="DMD uses HBBFT consensus: every block is final the moment it is produced.">
          <span className="live-dot" key={String(block?.number)} aria-hidden="true" />
          {rpcDown ? 'Network unreachable' : block ? `Block ${block.number.toLocaleString('en-US')}` : 'Connecting…'}
        </span>
        <WalletButton />
      </div>
    </header>
  )
}

function WalletButton() {
  const { account, myName, wallets, connect, disconnect, wrongChain, switchChain } = useApp()
  const [open, setOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  if (account && wrongChain) return <button className="btn warn-btn" onClick={() => void switchChain()}>Switch to DMD</button>
  return (
    <>
      <button className={`btn ${account ? 'account-btn' : 'primary'}`} onClick={() => setOpen(true)}>
        {account ? <><Avatar address={account} /><span>{myName ? `${myName}.dmd` : shortAddress(account)}</span></> : 'Connect wallet'}
      </button>
      {open && (
        <Modal title={account ? 'Your wallet' : 'Connect a wallet'} onClose={() => { setOpen(false); setError(null) }}>
          {account ? (
            <div className="wallet-panel">
              <Avatar address={account} size={44} />
              {myName && <strong className="wallet-name">{myName}.dmd</strong>}
              <code className="mono-addr">{account}</code>
              <div className="row-actions">
                <button className="btn ghost" onClick={() => void navigator.clipboard?.writeText(account)}>Copy address</button>
                <a className="btn ghost" href={`${EXPLORER_URL}/address/${account}`} target="_blank" rel="noreferrer noopener">View on explorer</a>
                <button className="btn ghost" onClick={() => { disconnect(); setOpen(false) }}>Disconnect</button>
              </div>
            </div>
          ) : wallets.length ? (
            <ul className="wallet-list">
              {wallets.map((w) => (
                <li key={w.uuid}>
                  <button className="token-row" onClick={() => connect(w).then(() => setOpen(false), (e) => setError(e?.code === 4001 ? 'You rejected the connection in your wallet.' : 'The wallet couldn’t connect. Unlock it and try again.'))}>
                    {w.icon ? <img src={w.icon} alt="" width={28} height={28} /> : <span className="token-badge">W</span>}
                    <span className="token-row-text"><strong>{w.name}</strong></span>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="hint">No browser wallet found. Install a wallet such as MetaMask or Rabby, then reload this page. DMDSwap adds the DMD Diamond network for you.</p>
          )}
          {error && <p className="hint bad">{error}</p>}
        </Modal>
      )}
    </>
  )
}
