# DMDSwap — Web app

Swap, provide liquidity and pay **DMD Names** on DMD Diamond (chain 17771).
React 19 + viem 2 + Vite 7, three runtime dependencies, no third-party scripts, fonts or trackers.

## Deploy to Vercel

1. **Deploy the contracts first** (see `../contracts/README.md`). The deploy script writes
   `contracts/deployments/dmd-mainnet.json`.
2. **Push this repository to GitHub/GitLab** and import it in Vercel. Set **Root Directory** to `frontend`.
   Vercel reads `vercel.json` (framework, build command, output dir, security headers) automatically.
3. **Add the contract addresses** as Production environment variables (Project → Settings → Environment Variables):

   | Variable | From `deployments/dmd-mainnet.json` |
   |---|---|
   | `VITE_FACTORY` | `factory` |
   | `VITE_ROUTER` | `router` |
   | `VITE_NAME_ROUTER` | `nameRouter` |
   | `VITE_NAME_RESOLVER` | `nameResolver` |
   | `VITE_WDMD` | `wdmd` |
   | `VITE_TIMELOCK` | `timelock` |

   (Alternatively paste the JSON into `src/deployment.json` and commit it.)
4. **Deploy.** Until the addresses are set, the site loads and shows a configuration notice; nothing can be traded.

CLI alternative: `cd frontend && npx vercel --prod` (then add the env vars and run it again).

## Local development
```bash
npm ci
npm run dev        # http://localhost:5173
npm test           # 28 tests: swap math vs. Solidity reference vectors, DMD Name rules
npm run build      # typecheck + production build into dist/
npm run sync-abi   # regenerate src/abi/generated.ts after changing contracts (needs `forge build`)
```

## What users get
- **Swap** with live prices recomputed every block, best route (direct or via WDMD), price impact,
  minimum received / maximum spent, fee breakdown (0.15% to LPs, 0.15% to DMDSwap) and wrap/unwrap.
- **Swap and send** to any address or **DMD Name** (`alice` → alice.dmd), resolved on-chain every block.
- **Send** DMD or tokens to an address or DMD Name.
- **Liquidity**: create pools, add with the pool ratio enforced, remove 25/50/75/100% (as DMD or WDMD).
- **Pools** list with reserves and your share.

## Front-running and fairness protections in the UI
- Default slippage 0.5%; warning above 1%; hard cap 15%. Exact-input swaps always send a non-zero minimum
  (the contracts also reject zero).
- Price impact warning above 3%, red above 10%, **blocked above 15%**.
- Before signing, the quote is refreshed; if it got worse by more than 0.1% you must accept the new price.
- Deadlines use the chain’s clock, not the computer’s.
- Every transaction is **simulated against the live chain first**; reverts are shown as plain messages before
  anything is signed.
- DMD’s HBBFT consensus gives instant finality: the first receipt is final, shown as “Final in block N”.

## Other security measures
- Strict Content-Security-Policy (meta tag + HTTP header): only this site and `https://rpc.bit.diamonds`.
- `frame-ancestors 'none'`, `X-Frame-Options: DENY` and a frame-busting check (clickjacking).
- Exact-amount token approvals by default (USDT-style reset-to-zero handled).
- Imported tokens require an explicit acknowledgement; symbols are sanitized (no look-alike Unicode) and
  `DMD`/`WDMD` impersonators are flagged.
- Recipient guard: DMDSwap contracts and token contracts can’t be chosen as recipients; contract recipients
  are flagged; names are re-resolved right before signing and again on-chain by the contract.
- Wallet discovery via EIP-6963; only inline `data:` wallet icons are rendered.
- Pin exact dependency versions and keep `package-lock.json` committed (`npm ci` on Vercel).

## Official tokens and logos

Tokens on the official list appear for every user without importing, show their logo, and are never
flagged with the “!” mark or the “Unlisted token” label.

### Add a token
1. Get the token’s contract address from the token’s own team, and check it on the DMD explorer.
2. Put its logo in `public/tokens/`: a square PNG, SVG or WebP, at least 64×64 px, under 100 KB,
   with a simple file name such as `abc.png`.
3. Add an entry to `src/official-tokens.json`:
   ```json
   {
     "name": "DMDSwap official token list",
     "coreLogos": { "DMD": "/tokens/dmd.png", "WDMD": "/tokens/wdmd.png" },
     "tokens": [
       { "address": "0xTokenContractAddress", "symbol": "ABC", "name": "ABC Token", "decimals": 18, "logo": "/tokens/abc.png" }
     ]
   }
   ```
4. Recommended: run `npm run check-tokens:chain`. It compares each symbol and decimals with DMD mainnet.
5. Commit and push. Vercel rebuilds automatically. The build stops with a plain explanation if any entry has a
   mistake (bad address, missing logo file, duplicate, wrong decimals format).

**DMD and WDMD logos:** put the files in `public/tokens/` and set their paths under `coreLogos`.
**Changing a logo:** use a new file name (for example `abc-v2.png`) so browsers don’t keep the old cached image.
**Removing a token:** delete its entry. Users can still import it by address, and it then shows as unverified.

### Built-in safety rules
- Logos must be files on this site (`/tokens/...`). Links to other websites are rejected, and the site’s
  security policy would block them anyway.
- At startup the app checks each official token’s decimals on-chain and hides any entry that doesn’t match
  or has no contract, so a typo can never show users wrong amounts.
- An imported token that copies an official symbol is shown with a “?” after its symbol.
