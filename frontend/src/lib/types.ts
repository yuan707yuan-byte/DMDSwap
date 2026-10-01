import type { Address } from 'viem'

export type Token = {
  address: Address | 'native'
  symbol: string
  name: string
  decimals: number
  /** native/core/official are trusted (no warnings); imported/pool tokens are unverified and show warnings */
  source: 'native' | 'core' | 'official' | 'imported' | 'pool'
  /** same-site logo path, e.g. /tokens/abc.png */
  logo?: string
}

export type RecipientMode = 'self' | 'address' | 'name'

export type Recipient =
  | { mode: 'self' }
  | { mode: 'address'; address: Address }
  | { mode: 'name'; name: string; address: Address }
