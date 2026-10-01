import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { getAddress, type Address, type Hash } from 'viem'
import { erc20Abi } from './abi/generated'
import { makeWalletClient, publicClient, type WalletClient } from './lib/client'
import { CHAIN_ID, IS_DEPLOYED, LIMITS } from './lib/config'
import { friendlyError } from './lib/errors'
import { activeNameOf } from './lib/resolve'
import { OFFICIAL_ADDRESSES, OFFICIAL_TOKENS } from './lib/officialTokens'
import { CORE_TOKENS, loadImportedTokens, saveImportedTokens, tokenKey } from './lib/tokens'
import { simulateAndSend, waitFinal, type ContractCall } from './lib/tx'
import type { Token } from './lib/types'
import { currentChainId, discoverWallets, ensureDmdChain, requestAccount, type WalletInfo } from './lib/wallet'

export type Settings = { slippageBps: number; deadlineMin: number; unlimitedApproval: boolean }
export type Toast = { id: number; title: string; body?: string; status: 'pending' | 'success' | 'error'; hash?: Hash }
export type TxStep = { label: string; call?: ContractCall; transfer?: { to: Address; value: bigint } }
export type Tab = 'swap' | 'liquidity' | 'send' | 'pools'

type App = {
  wallets: WalletInfo[]
  walletInfo: WalletInfo | null
  account: Address | null
  wrongChain: boolean
  myName: string | null
  connect: (w: WalletInfo) => Promise<void>
  disconnect: () => void
  switchChain: () => Promise<void>
  block: { number: bigint; timestamp: bigint } | null
  rpcDown: boolean
  settings: Settings
  updateSettings: (s: Partial<Settings>) => void
  tokens: Token[]
  addToken: (t: Token) => void
  refreshKey: number
  toasts: Toast[]
  dismissToast: (id: number) => void
  runTx: (title: string, steps: TxStep[]) => Promise<boolean>
  tab: Tab
  setTab: (t: Tab) => void
  liquidityPrefill: [Token, Token] | null
  openLiquidity: (a: Token, b: Token) => void
}

const Ctx = createContext<App | null>(null)
export const useApp = () => {
  const v = useContext(Ctx)
  if (!v) throw new Error('useApp outside provider')
  return v
}

const SETTINGS_KEY = 'dmdswap.settings.v1'
const WALLET_KEY = 'dmdswap.wallet.v1'

function loadSettings(): Settings {
  const d = { slippageBps: LIMITS.defaultSlippageBps, deadlineMin: LIMITS.defaultDeadlineMin, unlimitedApproval: false }
  try {
    const s = JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}') as Partial<Settings>
    const slip = Number(s.slippageBps)
    const dl = Number(s.deadlineMin)
    return {
      slippageBps: Number.isInteger(slip) && slip > 0 && slip <= LIMITS.maxSlippageBps ? slip : d.slippageBps,
      deadlineMin: Number.isFinite(dl) && dl >= 1 && dl <= 60 ? dl : d.deadlineMin,
      unlimitedApproval: s.unlimitedApproval === true,
    }
  } catch {
    return d
  }
}

export function AppProvider({ children }: { children: ReactNode }) {
  const [wallets, setWallets] = useState<WalletInfo[]>([])
  const [walletInfo, setWalletInfo] = useState<WalletInfo | null>(null)
  const [account, setAccount] = useState<Address | null>(null)
  const [chainId, setChainId] = useState<number | null>(null)
  const [myName, setMyName] = useState<string | null>(null)
  const [block, setBlock] = useState<App['block']>(null)
  const [rpcDown, setRpcDown] = useState(false)
  const [settings, setSettings] = useState<Settings>(loadSettings)
  const [imported, setImported] = useState<Token[]>(loadImportedTokens)
  const [official, setOfficial] = useState<Token[]>(OFFICIAL_TOKENS)
  const [refreshKey, setRefreshKey] = useState(0)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [tab, setTab] = useState<Tab>('swap')
  const [liquidityPrefill, setLiquidityPrefill] = useState<[Token, Token] | null>(null)
  const toastId = useRef(0)
  const walletClient = useRef<WalletClient | null>(null)

  useEffect(() => discoverWallets(setWallets), [])

  // Live chain head. HBBFT blocks are final when produced.
  useEffect(() => {
    if (!IS_DEPLOYED) return
    return publicClient.watchBlocks({
      emitOnBegin: true,
      pollingInterval: 1_500,
      onBlock: (b) => {
        setRpcDown(false)
        setBlock((prev) => (prev && b.number !== null && b.number <= prev.number ? prev : { number: b.number ?? 0n, timestamp: b.timestamp }))
      },
      onError: () => setRpcDown(true),
    })
  }, [])

  const bindWallet = useCallback((info: WalletInfo, acct: Address, chain: number) => {
    walletClient.current = makeWalletClient(info.provider, acct)
    setWalletInfo(info)
    setAccount(acct)
    setChainId(chain)
    try {
      localStorage.setItem(WALLET_KEY, info.rdns || info.uuid)
    } catch { /* ignore */ }
  }, [])

  const connect = useCallback(async (info: WalletInfo) => {
    const acct = await requestAccount(info.provider)
    try {
      await ensureDmdChain(info.provider)
    } catch { /* user may switch later; the UI shows a switch button */ }
    bindWallet(info, acct, await currentChainId(info.provider))
  }, [bindWallet])

  const disconnect = useCallback(() => {
    walletClient.current = null
    setWalletInfo(null)
    setAccount(null)
    setMyName(null)
    try {
      localStorage.removeItem(WALLET_KEY)
    } catch { /* ignore */ }
  }, [])

  // Silent reconnect (eth_accounts never opens a popup).
  useEffect(() => {
    if (walletInfo) return
    let saved: string | null = null
    try {
      saved = localStorage.getItem(WALLET_KEY)
    } catch { /* ignore */ }
    const w = wallets.find((x) => (x.rdns || x.uuid) === saved)
    if (!w) return
    void (async () => {
      const accts = (await w.provider.request({ method: 'eth_accounts' })) as string[]
      if (accts?.length) bindWallet(w, getAddress(accts[0]), await currentChainId(w.provider))
    })().catch(() => undefined)
  }, [wallets, walletInfo, bindWallet])

  // Follow account / network changes made inside the wallet.
  useEffect(() => {
    if (!walletInfo) return
    const p = walletInfo.provider
    const onAccounts = (accts: string[]) => (accts?.length ? bindWallet(walletInfo, getAddress(accts[0]), chainId ?? 0) : disconnect())
    const onChain = (hex: string) => setChainId(Number.parseInt(hex, 16))
    p.on?.('accountsChanged', onAccounts as never)
    p.on?.('chainChanged', onChain as never)
    return () => {
      p.removeListener?.('accountsChanged', onAccounts as never)
      p.removeListener?.('chainChanged', onChain as never)
    }
  }, [walletInfo, chainId, bindWallet, disconnect])

  useEffect(() => {
    if (!account || !IS_DEPLOYED) return setMyName(null)
    activeNameOf(account).then(setMyName).catch(() => setMyName(null))
  }, [account, refreshKey])

  const switchChain = useCallback(async () => {
    if (!walletInfo) return
    await ensureDmdChain(walletInfo.provider)
    setChainId(await currentChainId(walletInfo.provider))
  }, [walletInfo])

  const updateSettings = useCallback((s: Partial<Settings>) => {
    setSettings((prev) => {
      const next = { ...prev, ...s }
      try {
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(next))
      } catch { /* ignore */ }
      return next
    })
  }, [])

  // Safety net for the official list: hide any entry whose decimals don't match the chain (amounts would be
  // wrong by orders of magnitude) or whose address has no contract. Network hiccups keep the token.
  useEffect(() => {
    if (!IS_DEPLOYED || OFFICIAL_TOKENS.length === 0) return
    let live = true
    Promise.all(OFFICIAL_TOKENS.map(async (t) => {
      const address = t.address as Address
      try {
        const d = await publicClient.readContract({ address, abi: erc20Abi, functionName: 'decimals' })
        if (Number(d) === t.decimals) return t
        console.error(`[DMDSwap] official token ${t.symbol}: list says ${t.decimals} decimals, chain says ${d}. Hidden.`)
        return null
      } catch {
        const code = await publicClient.getCode({ address }).catch(() => 'unknown')
        if (code === undefined || code === '0x') {
          console.error(`[DMDSwap] official token ${t.symbol}: no contract at ${address}. Hidden.`)
          return null
        }
        return t
      }
    })).then((list) => live && setOfficial(list.filter((t): t is Token => t !== null)))
    return () => {
      live = false
    }
  }, [])

  const tokens = useMemo(() => {
    const seen = new Set<string>()
    return [...CORE_TOKENS, ...official, ...imported].filter((t) => (seen.has(tokenKey(t)) ? false : (seen.add(tokenKey(t)), true)))
  }, [official, imported])

  const addToken = useCallback((t: Token) => {
    setImported((prev) => {
      if (prev.some((x) => tokenKey(x) === tokenKey(t)) || CORE_TOKENS.some((x) => tokenKey(x) === tokenKey(t))) return prev
      if (t.address !== 'native' && OFFICIAL_ADDRESSES.has(t.address.toLowerCase())) return prev
      const next = [...prev, { ...t, source: 'imported' as const }]
      saveImportedTokens(next)
      return next
    })
  }, [])

  const pushToast = useCallback((t: Omit<Toast, 'id'>) => {
    const id = ++toastId.current
    setToasts((prev) => [...prev.slice(-3), { ...t, id }])
    return id
  }, [])
  const patchToast = useCallback((id: number, t: Partial<Toast>) => setToasts((prev) => prev.map((x) => (x.id === id ? { ...x, ...t } : x))), [])
  const dismissToast = useCallback((id: number) => setToasts((prev) => prev.filter((x) => x.id !== id)), [])

  const runTx = useCallback(async (title: string, steps: TxStep[]) => {
    const wc = walletClient.current
    if (!wc || !account || !walletInfo) return false
    const id = pushToast({ title, body: 'Preparing…', status: 'pending' })
    try {
      if ((await currentChainId(walletInfo.provider)) !== CHAIN_ID) await ensureDmdChain(walletInfo.provider)
      let lastBlock: bigint | null = null
      for (const [i, step] of steps.entries()) {
        const prefix = steps.length > 1 ? `Step ${i + 1} of ${steps.length}: ` : ''
        patchToast(id, { body: `${prefix}${step.label}. Confirm in your wallet.` })
        const hash = step.call
          ? await simulateAndSend(wc, account, step.call)
          : await wc.sendTransaction({ to: step.transfer!.to, value: step.transfer!.value, account, chain: wc.chain })
        patchToast(id, { body: `${prefix}${step.label}. Waiting for the next block…`, hash })
        const receipt = await waitFinal(hash)
        lastBlock = receipt.blockNumber
      }
      patchToast(id, { status: 'success', body: `Final in block ${lastBlock?.toLocaleString('en-US')}. DMD blocks can't be reverted.` })
      window.setTimeout(() => dismissToast(id), 12_000)
      return true
    } catch (e) {
      patchToast(id, { status: 'error', body: friendlyError(e) })
      return false
    } finally {
      setRefreshKey((k) => k + 1)
    }
  }, [account, walletInfo, pushToast, patchToast, dismissToast])

  const openLiquidity = useCallback((a: Token, b: Token) => {
    setLiquidityPrefill([a, b])
    setTab('liquidity')
  }, [])

  const value: App = {
    wallets, walletInfo, account, wrongChain: !!account && chainId !== CHAIN_ID, myName,
    connect, disconnect, switchChain, block, rpcDown, settings, updateSettings, tokens, addToken,
    refreshKey, toasts, dismissToast, runTx, tab, setTab, liquidityPrefill, openLiquidity,
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}
