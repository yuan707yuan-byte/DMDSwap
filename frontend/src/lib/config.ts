import { defineChain, getAddress, isAddress, parseEther, zeroAddress, type Address } from 'viem'
import deployment from '../deployment.json'

export const CHAIN_ID = 17771
export const RPC_URL = 'https://rpc.bit.diamonds'
export const EXPLORER_URL = 'https://explorer.bit.diamonds'
export const NAMES_APP_URL = 'https://ui.bit.diamonds/names'

// Footer links (open in a new tab).
export const SOCIAL_LINKS = [
  { label: 'X', href: 'https://x.com/DMDSwap' },
  { label: 'Telegram', href: 'https://t.me/DMDSwap' },
  { label: 'DOCS Guide', href: '/docs/DMDSwap_Document_Guide.pdf' },
] as const

export const dmdChain = defineChain({
  id: CHAIN_ID,
  name: 'DMD Diamond',
  nativeCurrency: { name: 'DMD', symbol: 'DMD', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: 'DMD Explorer', url: EXPLORER_URL } },
})

/** Vercel env vars (VITE_*) override src/deployment.json. Invalid values resolve to zero (=> "not deployed"). */
function addr(envValue: string | undefined, fallback: string): Address {
  const v = (envValue ?? '').trim() || fallback
  return isAddress(v, { strict: false }) ? getAddress(v) : zeroAddress
}

const env = import.meta.env
export const ADDRESSES = {
  factory: addr(env.VITE_FACTORY, deployment.factory),
  router: addr(env.VITE_ROUTER, deployment.router),
  nameRouter: addr(env.VITE_NAME_ROUTER, deployment.nameRouter),
  nameResolver: addr(env.VITE_NAME_RESOLVER, deployment.nameResolver),
  wdmd: addr(env.VITE_WDMD, deployment.wdmd),
  timelock: addr(env.VITE_TIMELOCK, deployment.timelock),
} as const

export const IS_DEPLOYED = Object.values(ADDRESSES).every((a) => a !== zeroAddress)
export const PROTOCOL_ADDRESSES = new Set<string>(Object.values(ADDRESSES).map((a) => a.toLowerCase()))

export const LIMITS = {
  defaultSlippageBps: 50, // 0.5 %
  warnSlippageBps: 100, // > 1 % shows a sandwich-risk warning
  maxSlippageBps: 1500, // 15 % hard cap in the UI
  defaultDeadlineMin: 10,
  impactWarnBps: 300,
  impactDangerBps: 1000,
  impactBlockBps: 1500, // swaps above 15 % price impact are blocked
  quoteDriftBps: 10, // re-confirm if the fresh quote is > 0.1 % worse than what the user reviewed
  nativeGasReserve: parseEther('0.05'),
  maxPoolsScanned: 200,
} as const
