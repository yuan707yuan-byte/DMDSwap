import { EXPLORER_URL, NAMES_APP_URL } from '../lib/config'
import { shortAddress } from '../lib/format'
import type { RecipientMode } from '../lib/types'
import type { RecipientState } from '../hooks/useRecipient'
import { Avatar } from './Brand'

const LABELS: Record<RecipientMode, string> = { self: 'My wallet', address: 'Address', name: 'DMD Name' }

export function RecipientField({ r, allowSelf }: { r: RecipientState; allowSelf: boolean }) {
  const modes: RecipientMode[] = allowSelf ? ['self', 'name', 'address'] : ['name', 'address']
  const resolvedAddress = r.resolved && r.resolved.mode !== 'self' ? r.resolved.address : null
  return (
    <div className="recipient">
      <div className="segmented" role="radiogroup" aria-label="Send to">
        <span className="segmented-label">Send to</span>
        {modes.map((m) => (
          <button key={m} role="radio" aria-checked={r.mode === m} className={r.mode === m ? 'on' : ''} onClick={() => { r.setMode(m); r.setInput('') }}>
            {LABELS[m]}
          </button>
        ))}
      </div>
      {r.mode !== 'self' && (
        <div className={`recipient-input${r.status === 'error' ? ' bad' : r.status === 'ok' ? ' good' : ''}`}>
          <input
            aria-label={r.mode === 'name' ? 'DMD Name' : 'Recipient address'}
            placeholder={r.mode === 'name' ? 'alice' : '0x…'}
            value={r.input}
            onChange={(e) => r.setInput(e.target.value)}
            spellCheck={false}
            autoComplete="off"
            autoCapitalize="none"
          />
          {r.mode === 'name' && <span className="suffix">.dmd</span>}
        </div>
      )}
      {r.mode === 'name' && r.input && r.normalizedName !== r.input.trim() && r.status !== 'error' && (
        <p className="hint">DMD Names are lowercase. Looking up {r.normalizedName}.dmd</p>
      )}
      {r.status === 'checking' && <p className="hint">Checking on DMD Diamond…</p>}
      {r.status === 'error' && r.message && <p className="hint bad">{r.message}{r.mode === 'name' && <> <a className="link" href={NAMES_APP_URL} target="_blank" rel="noreferrer noopener">Open DMD Names</a></>}</p>}
      {resolvedAddress && (
        <div className="resolved">
          <Avatar address={resolvedAddress} size={26} />
          <div>
            {r.resolved?.mode === 'name' && <strong>{r.resolved.name}.dmd</strong>}
            <a className="mono-addr" href={`${EXPLORER_URL}/address/${resolvedAddress}`} target="_blank" rel="noreferrer noopener" title={resolvedAddress}>
              {resolvedAddress}
            </a>
          </div>
        </div>
      )}
      {resolvedAddress && r.isContract && <p className="hint warn">This address is a smart contract. Make sure it can handle the tokens you send.</p>}
      {r.mode === 'name' && r.status === 'ok' && (
        <p className="hint">Checked on every block. If this name changes owner before your transaction executes, it reverts and nothing is sent.</p>
      )}
      {r.mode === 'address' && resolvedAddress && <p className="hint">Sending to {shortAddress(resolvedAddress)}. Transfers can’t be undone.</p>}
    </div>
  )
}
