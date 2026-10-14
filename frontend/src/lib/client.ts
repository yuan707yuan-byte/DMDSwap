import { createPublicClient, createWalletClient, custom, http, type Address, type EIP1193Provider } from 'viem'
import { dmdChain, RPC_URL } from './config'

// Single trusted RPC (matches the CSP connect-src). No batching: works with any JSON-RPC proxy.
export const publicClient = createPublicClient({
  chain: dmdChain,
  transport: http(RPC_URL, { retryCount: 2, timeout: 15_000 }),
  pollingInterval: 1_500,
})

export function makeWalletClient(provider: EIP1193Provider, account: Address) {
  return createWalletClient({ account, chain: dmdChain, transport: custom(provider) })
}
export type WalletClient = ReturnType<typeof makeWalletClient>
