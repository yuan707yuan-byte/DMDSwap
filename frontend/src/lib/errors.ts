import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from 'viem'

const MESSAGES: Record<string, string> = {
  InsufficientOutputAmount: 'The price moved beyond your slippage tolerance before your trade executed. Nothing was spent.',
  ExcessiveInputAmount: 'The price moved and the trade would cost more than your maximum. Nothing was spent.',
  ZeroSlippageProtection: 'This trade has no minimum output. Set a slippage tolerance and try again.',
  Expired: 'The transaction deadline passed. Review the trade and submit it again.',
  Paused: 'Trading is paused by the DMDSwap admin. Removing liquidity still works.',
  RecipientMismatch: 'This DMD Name now points to a different wallet than the one you confirmed. Nothing was sent.',
  NameNotResolvable: 'This DMD Name isn’t active, has expired, or is blocked. Nothing was sent.',
  PairNotFound: 'There is no pool for this pair yet. Add liquidity to create one.',
  InsufficientLiquidity: 'The pool doesn’t have enough liquidity for this trade.',
  InsufficientInputAmount: 'The amount is too small to trade.',
  InsufficientAAmount: 'The pool ratio moved beyond your slippage tolerance. Nothing was deposited.',
  InsufficientBAmount: 'The pool ratio moved beyond your slippage tolerance. Nothing was deposited.',
  InsufficientLiquidityMinted: 'The deposit is too small to create liquidity tokens.',
  InsufficientLiquidityBurned: 'The amount of liquidity to remove is too small.',
  KInvariant: 'The pool rejected this trade because its pricing check failed. Try a smaller amount.',
  DMDTransferFailed: 'The recipient can’t receive DMD. Choose a different recipient or receive WDMD.',
  InvalidRecipient: 'That recipient isn’t allowed. Funds sent there would be lost.',
  InvalidPath: 'This route isn’t supported.',
  ERC20InsufficientBalance: 'Your balance is too low for this amount.',
  ERC20InsufficientAllowance: 'The approval is lower than the amount. Approve again and retry.',
  PermitFailed: 'The signature was rejected. Approve the liquidity tokens instead.',
}

export function friendlyError(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName
      if (name && MESSAGES[name]) return MESSAGES[name]
      if (revert.reason) return `The contract rejected the transaction: ${revert.reason}`
    }
    return error.shortMessage
  }
  const code = (error as { code?: number })?.code
  if (code === 4001) return 'You rejected the request in your wallet.'
  return error instanceof Error ? error.message : 'Something went wrong.'
}
