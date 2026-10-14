import { getAddress, toHex, type Address, type EIP1193Provider } from 'viem'
import { CHAIN_ID, EXPLORER_URL, RPC_URL } from './config'

export type WalletInfo = { uuid: string; name: string; icon: string; rdns: string; provider: EIP1193Provider }

/** EIP-6963 multi-wallet discovery, with a legacy window.ethereum fallback. */
export function discoverWallets(onChange: (list: WalletInfo[]) => void): () => void {
  const found = new Map<string, WalletInfo>()
  const emit = () => onChange([...found.values()])
  const onAnnounce = (event: Event) => {
    const detail = (event as CustomEvent).detail as { info?: Partial<WalletInfo>; provider?: EIP1193Provider }
    const info = detail?.info
    if (!info?.uuid || !info.name || !detail.provider) return
    // Only accept inline data: icons (never fetch remote images announced by a page script).
    const icon = typeof info.icon === 'string' && info.icon.startsWith('data:image/') ? info.icon : ''
    found.set(info.uuid, { uuid: info.uuid, name: String(info.name).slice(0, 40), icon, rdns: String(info.rdns ?? ''), provider: detail.provider })
    emit()
  }
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
  const legacy = (window as unknown as { ethereum?: EIP1193Provider }).ethereum
  const timer = window.setTimeout(() => {
    if (found.size === 0 && legacy) {
      found.set('legacy', { uuid: 'legacy', name: 'Browser wallet', icon: '', rdns: 'legacy', provider: legacy })
      emit()
    }
  }, 500)
  return () => {
    window.removeEventListener('eip6963:announceProvider', onAnnounce)
    window.clearTimeout(timer)
  }
}

export async function requestAccount(provider: EIP1193Provider): Promise<Address> {
  const accounts = (await provider.request({ method: 'eth_requestAccounts' })) as string[]
  if (!accounts?.length) throw new Error('The wallet did not share an account.')
  return getAddress(accounts[0])
}

export async function currentChainId(provider: EIP1193Provider): Promise<number> {
  return Number.parseInt((await provider.request({ method: 'eth_chainId' })) as string, 16)
}

/** Switch to DMD mainnet, adding it to the wallet first if needed. */
export async function ensureDmdChain(provider: EIP1193Provider): Promise<void> {
  if ((await currentChainId(provider)) === CHAIN_ID) return
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: toHex(CHAIN_ID) }] })
  } catch (error) {
    const code = (error as { code?: number; data?: { originalError?: { code?: number } } })?.code
    const nested = (error as { data?: { originalError?: { code?: number } } })?.data?.originalError?.code
    if (code !== 4902 && nested !== 4902) throw error
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId: toHex(CHAIN_ID),
          chainName: 'DMD Diamond',
          nativeCurrency: { name: 'DMD', symbol: 'DMD', decimals: 18 },
          rpcUrls: [RPC_URL],
          blockExplorerUrls: [EXPLORER_URL],
        },
      ],
    })
  }
}
