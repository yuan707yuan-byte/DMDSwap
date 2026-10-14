// Validates src/official-tokens.json and the logo files in public/tokens.
//   npm run check-tokens          offline checks (also runs automatically before every build)
//   npm run check-tokens:chain    also compares symbol and decimals with DMD mainnet
import { existsSync, readFileSync, statSync } from 'node:fs'
import { createPublicClient, getAddress, http, isAddress } from 'viem'

const root = new URL('../', import.meta.url)
const list = JSON.parse(readFileSync(new URL('src/official-tokens.json', root), 'utf8'))
const LOGO = /^\/tokens\/[A-Za-z0-9._-]+\.(png|svg|webp|jpg|jpeg)$/
const PRINTABLE = /^[\x20-\x7E]+$/
const errors = []
const warnings = []

function checkLogo(where, logo) {
  if (logo === undefined || logo === '') return warnings.push(`${where}: no logo (a letter badge is shown instead)`)
  if (typeof logo !== 'string' || !LOGO.test(logo)) return errors.push(`${where}: logo must look like /tokens/name.png`)
  const file = new URL(`public${logo}`, root)
  if (!existsSync(file)) return errors.push(`${where}: logo file public${logo} does not exist`)
  const kb = statSync(file).size / 1024
  if (kb > 200) warnings.push(`${where}: logo is ${kb.toFixed(0)} KB; keep logos under 100 KB so the list loads fast`)
}

for (const key of ['DMD', 'WDMD']) checkLogo(`coreLogos.${key}`, list.coreLogos?.[key])
if (!Array.isArray(list.tokens)) errors.push('"tokens" must be a list')
const seenA = new Set()
const seenS = new Set()
for (const [i, t] of (list.tokens ?? []).entries()) {
  const where = `tokens[${i}]${t?.symbol ? ` (${t.symbol})` : ''}`
  if (!isAddress(String(t?.address ?? '').trim(), { strict: false })) { errors.push(`${where}: invalid address`); continue }
  const a = getAddress(t.address.trim()).toLowerCase()
  if (seenA.has(a)) errors.push(`${where}: address listed twice`)
  seenA.add(a)
  const sym = String(t.symbol ?? '').trim()
  if (!sym || sym.length > 12 || !PRINTABLE.test(sym)) errors.push(`${where}: symbol must be 1-12 plain characters`)
  if (['DMD', 'WDMD'].includes(sym.toUpperCase())) errors.push(`${where}: DMD and WDMD are built in; don't list them`)
  if (seenS.has(sym.toUpperCase())) errors.push(`${where}: symbol listed twice`)
  seenS.add(sym.toUpperCase())
  const name = String(t.name ?? '').trim()
  if (!name || name.length > 40 || !PRINTABLE.test(name)) errors.push(`${where}: name must be 1-40 plain characters`)
  if (!Number.isInteger(t.decimals) || t.decimals < 0 || t.decimals > 36) errors.push(`${where}: decimals must be a whole number 0-36`)
  checkLogo(where, t.logo)
}

if (process.argv.includes('--chain') && errors.length === 0) {
  const client = createPublicClient({ transport: http('https://rpc.bit.diamonds') })
  const abi = [
    { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
    { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  ]
  for (const t of list.tokens) {
    const address = getAddress(t.address.trim())
    try {
      const [d, s] = await Promise.all([
        client.readContract({ address, abi, functionName: 'decimals' }),
        client.readContract({ address, abi, functionName: 'symbol' }),
      ])
      if (Number(d) !== t.decimals) errors.push(`${t.symbol}: list says ${t.decimals} decimals, chain says ${d}`)
      if (s !== t.symbol) warnings.push(`${t.symbol}: on-chain symbol is "${s}"`)
      else console.log(`  ok  ${t.symbol.padEnd(12)} ${address}  ${d} decimals`)
    } catch {
      errors.push(`${t.symbol}: could not read the token at ${address} on DMD mainnet`)
    }
  }
}

for (const w of warnings) console.log(`  note  ${w}`)
if (errors.length) {
  console.error('\nofficial-tokens.json has problems:')
  for (const e of errors) console.error(`  x  ${e}`)
  process.exit(1)
}
console.log(`official token list ok: ${list.tokens.length} token(s)`)
