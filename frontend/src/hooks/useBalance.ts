import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { erc20Abi } from '../abi/generated'
import { publicClient } from '../lib/client'
import type { Token } from '../lib/types'
import { useApp } from '../store'

export async function readBalance(token: Token, account: Address): Promise<bigint> {
  return token.address === 'native'
    ? publicClient.getBalance({ address: account })
    : publicClient.readContract({ address: token.address, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
}

/** Balance that refreshes on every new block and after every transaction. */
export function useBalance(token: Token | null): bigint | null {
  const { account, block, refreshKey } = useApp()
  const [value, setValue] = useState<bigint | null>(null)
  const blockNo = block?.number
  useEffect(() => {
    if (!token || !account) return setValue(null)
    let live = true
    readBalance(token, account).then((v) => live && setValue(v)).catch(() => undefined)
    return () => {
      live = false
    }
  }, [token, account, blockNo, refreshKey])
  return value
}
