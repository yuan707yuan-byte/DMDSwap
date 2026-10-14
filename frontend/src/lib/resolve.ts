import type { Address } from 'viem'
import { zeroAddress } from 'viem'
import { nameResolverAbi } from '../abi/generated'
import { publicClient } from './client'
import { ADDRESSES } from './config'

/** On-chain resolution through DmdNameResolver (7 independent checks). null = not safely resolvable. */
export async function resolveDmdName(name: string): Promise<Address | null> {
  const a = await publicClient.readContract({ address: ADDRESSES.nameResolver, abi: nameResolverAbi, functionName: 'resolve', args: [name] })
  return a === zeroAddress ? null : a
}

export async function activeNameOf(account: Address): Promise<string | null> {
  const n = await publicClient.readContract({ address: ADDRESSES.nameResolver, abi: nameResolverAbi, functionName: 'activeNameOf', args: [account] })
  return n || null
}
