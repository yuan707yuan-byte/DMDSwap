# DMDSwap — Smart Contracts

Constant-product DEX for **DMD Diamond v4** (chain ID `17771`) with native **DMD Names** payments.
Solidity 0.8.25 · EVM **london** · OpenZeppelin 5.0.2 — identical toolchain to DMD's own core contracts.

## Contracts

| Contract | Role | Upgradeable via |
|---|---|---|
| `core/DmdSwapFactory` | creates pairs, holds bounded fee params, emergency pause | UUPS → 24h timelock |
| `core/DmdSwapPair` | AMM pool + LP token (EIP-2612) | UpgradeableBeacon → 24h timelock (all pairs at once) |
| `periphery/DmdSwapRouter` | add/remove liquidity, all swap types, DMD⇄token | UUPS → 24h timelock |
| `names/DmdNameRouter` | swap-and-send / send to a DMD Name | UUPS → 24h timelock |
| `names/DmdNameResolver` | fund-safe resolution of official DMD Names | UUPS → 24h timelock |
| `token/WDMD` | wrapped DMD (1:1, no mint authority, no pause) | UUPS → 24h timelock |
| OZ `TimelockController` | **sole owner of everything**; delay 24h; ADMIN = proposer/executor/canceller | — |

## Fee model (active from the first swap)
- Trader pays **0.30 %** of the input amount.
- **Half (0.15 %) is transferred directly to the ADMIN wallet inside every swap**, in the token the trader paid
  (DMD trades pay the admin in WDMD — unwrap anytime with `WDMD.withdraw`). Event: `ProtocolFeePaid`.
- **Half (0.15 %) stays in the pool** and grows every LP position automatically.
- Hard caps no one can exceed: swap fee ≤ 1 %, admin share ≤ 50 % of the fee. Changes need the 24h timelock.
- A token that refuses transfers to the admin can't break its pool: that fee simply stays with LPs.

## Security properties (all covered by tests)
- **Front-running:** DMD's HBBFT consensus (threshold-encrypted block contributions, random transaction
  shuffling, no validator reordering) + contract guards: mandatory `amountOutMin > 0`, deadlines, `amountInMax`.
  `test_sandwichAttack_isBlockedBySlippageGuard` simulates a sandwich: the victim tx reverts instead of being exploited.
- **Instant finality:** provided by HBBFT — one receipt = final; no reorg handling needed.
- **DMD Names:** a name resolves only if 7 independent checks agree (valid syntax, live `.dmd` registrar,
  forward record, NFT owner, NOT expired, controller index, not DAO-blocked). DMD does **not** clear records of
  expired names — the adapter refuses them (`test_resolve_expiredName_failsClosed_despiteStaleRecord`).
  Each payment re-resolves on-chain and must match the address the user confirmed (`expectedRecipient`).
- Reentrancy locks on pairs and routers; read-only-reentrancy guard on `getReserves()`.
- Pause (admin, instant) stops swaps/adds/pair creation — **LP withdrawals can never be paused**.
  Unpause requires the 24h timelock.
- ERC-7201 namespaced storage everywhere (upgrade-safe); initializers locked; initialization atomic.
- Pair addresses always read from the factory (no init-code-hash bug class).

## Build & test
```bash
npm ci                                     # OpenZeppelin 5.0.2 (exact)
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge test                                 # 80 tests: unit, fuzz, stateful invariants, real DMD Names, deploy
./script/check-evm-compat.sh               # proves no PUSH0/TLOAD/TSTORE/MCOPY (DMD is a London EVM)
```
`test/fixtures/dmd-names/` contains build artifacts of the **official** DMD Names contracts
(DMDcoin/diamond-contracts-registry @ `e37c376`, v1.0.0) — integration tests run against real DMD code.

## Deploy (mainnet)
```bash
export ADMIN=0xYourAdminAddress           # use a hardware wallet: it controls everything (after 24h notice)
forge script script/Deploy.s.sol --rpc-url dmd_mainnet --broadcast --slow --ledger
```
Pre-flight aborts unless chain = 17771 and the official DMD Names contracts verify on-chain.
Post-flight aborts unless the timelock is the only owner, ADMIN holds exactly proposer/executor/canceller,
the deployer holds nothing, and fee recipient = ADMIN with a 50 % share. Addresses → `deployments/dmd-mainnet.json`.
Verify on Blockscout: `forge verify-contract <addr> <Contract> --chain 17771 --verifier blockscout --verifier-url https://explorer.bit.diamonds/api`.

## Governance runbook (24h timelock)
Every change is public for 24h before it can execute — users can exit if they disagree.
```bash
TL=<timelock>; DATA=$(cast calldata "setSwapFee(uint16)" 25); SALT=$(cast keccak "fee-2026-10")
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" <factory> 0 $DATA 0x00..00 $SALT 86400 --ledger
# ...24h later:
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" <factory> 0 $DATA 0x00..00 $SALT --ledger
```
- Upgrade a UUPS contract: target = proxy, data = `upgradeToAndCall(newImpl, 0x)`.
- Upgrade **all pairs**: target = beacon, data = `upgradeTo(newPairImpl)`.
- Emergency: `factory.pause()` directly from ADMIN (instant). Cancel a pending op: `cancel(id)`.
- New implementations must keep the ERC-7201 storage layout (append-only inside each namespace).

## Static analysis
Slither 0.10.4: **0 High**. Remaining items are by design: UQ112x112 TWAP encoding (divide-before-multiply,
identical to Uniswap V2), zero-amount guards (strict equality), intentional tuple skips (unused-return),
deadline/TWAP timestamps, event after `new BeaconProxy` (trusted, atomic init).

## Trust assumptions & limits — read before launch
- **Upgradeable by design (your requirement):** whoever controls ADMIN can, after the 24h delay, replace any
  logic — including pool and router logic that holds or can pull user funds. The delay is the users' protection.
- **Single admin key:** store it on a hardware wallet. Consider a multisig later (timelock roles can be changed).
- Users approve the routers; the UI defaults to exact-amount approvals to limit exposure to a malicious upgrade.
- Fee-on-transfer tokens: use the `...SupportingFeeOnTransferTokens` functions (UI does this automatically).
  Rebasing tokens are not supported.
- These tests and analyses are extensive but **are not a substitute for an independent professional audit**
  before mainnet launch.
