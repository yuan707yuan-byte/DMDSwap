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

/** The official Wrapped DMD. Fixed: the app never uses any other wrapper, whatever the configuration says. */
export const OFFICIAL_WDMD: Address = '0x2B1Bb4D22309af4330C216D797298b63Dbe97eA6'
/** DMD Diamond DAO: owns every DMDSwap contract (upgrades and settings go through DAO proposals). */
export const DMD_DAO: Address = '0xDA0da0da0Da0Da0Da0DA00DA0da0da0DA0DA0dA0'
export const DAO_UI_URL = 'https://ui.bit.diamonds/dao'

/** Vercel env vars (VITE_*) override src/deployment.json. Invalid values resolve to zero (=> "not deployed"). */
function addr(envValue: string | undefined, fallback: unknown): Address {
  const v = (envValue ?? '').trim() || (typeof fallback === 'string' ? fallback : '')
  return isAddress(v, { strict: false }) ? getAddress(v) : zeroAddress
}

const env = import.meta.env
const file = deployment as Record<string, unknown> // tolerant of older deployment.json layouts
export const ADDRESSES = {
  factory: addr(env.VITE_FACTORY, file.factory),
  router: addr(env.VITE_ROUTER, file.router),
  nameRouter: addr(env.VITE_NAME_ROUTER, file.nameRouter),
  nameResolver: addr(env.VITE_NAME_RESOLVER, file.nameResolver),
  wdmd: OFFICIAL_WDMD,
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
