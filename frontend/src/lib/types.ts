import type { Address } from 'viem'

export type Token = {
  address: Address | 'native'
  symbol: string
  name: string
  decimals: number
  /** native/core are built in; imported/pool tokens are unverified and show warnings */
  source: 'native' | 'core' | 'imported' | 'pool'
}

export type RecipientMode = 'self' | 'address' | 'name'

export type Recipient =
  | { mode: 'self' }
  | { mode: 'address'; address: Address }
  | { mode: 'name'; name: string; address: Address }
