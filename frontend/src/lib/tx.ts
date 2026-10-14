import type { Abi, Address, Hash } from 'viem'
import { maxUint256 } from 'viem'
import { erc20Abi } from '../abi/generated'
import { publicClient, type WalletClient } from './client'

export type ContractCall = { address: Address; abi: Abi; functionName: string; args: readonly unknown[]; value?: bigint }

type SimParams = Parameters<typeof publicClient.simulateContract>[0]

/** Simulates against the live chain first (surfaces reverts with readable reasons), then asks the wallet to sign. */
export async function simulateAndSend(wallet: WalletClient, account: Address, call: ContractCall): Promise<Hash> {
  const { request } = await publicClient.simulateContract({ ...call, account } as unknown as SimParams)
  return wallet.writeContract(request as Parameters<WalletClient['writeContract']>[0])
}

/** DMD (HBBFT) has instant finality: the first receipt is final. */
export async function waitFinal(hash: Hash) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 180_000 })
  if (receipt.status !== 'success') throw new Error('The transaction was included but reverted. Nothing changed.')
  return receipt
}

/** Deadline from the chain's own clock (immune to a wrong local clock). */
export async function deadlineFromChain(minutes: number): Promise<bigint> {
  const block = await publicClient.getBlock()
  return block.timestamp + BigInt(Math.round(minutes * 60))
}

export async function allowanceOf(token: Address, owner: Address, spender: Address): Promise<bigint> {
  return publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [owner, spender] })
}

export function approveCall(token: Address, spender: Address, amount: bigint): ContractCall {
  return { address: token, abi: erc20Abi as Abi, functionName: 'approve', args: [spender, amount] }
}

/**
 * Approval steps needed so `spender` can pull `amount`. Default is an EXACT approval (limits exposure if a
 * contract is ever upgraded maliciously). Tokens like USDT that require resetting to 0 first are handled.
 */
export async function approvalSteps(
  token: Address, owner: Address, spender: Address, amount: bigint, unlimited: boolean,
): Promise<ContractCall[]> {
  const current = await allowanceOf(token, owner, spender)
  if (current >= amount) return []
  const target = unlimited ? maxUint256 : amount
  if (current === 0n) return [approveCall(token, spender, target)]
  try {
    await publicClient.simulateContract({ ...approveCall(token, spender, target), account: owner } as unknown as SimParams)
    return [approveCall(token, spender, target)]
  } catch {
    return [approveCall(token, spender, 0n), approveCall(token, spender, target)]
  }
}
