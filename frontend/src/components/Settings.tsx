import { useState } from 'react'
import { LIMITS } from '../lib/config'
import { useApp } from '../store'

const PRESETS = [10, 50, 100]

export function SettingsPanel({ onClose }: { onClose: () => void }) {
  const { settings, updateSettings } = useApp()
  const [custom, setCustom] = useState(PRESETS.includes(settings.slippageBps) ? '' : String(settings.slippageBps / 100))
  const setCustomPct = (v: string) => {
    const s = v.replace(/[^\d.]/g, '').slice(0, 5)
    setCustom(s)
    const bps = Math.round(Number(s) * 100)
    if (s && bps > 0 && bps <= LIMITS.maxSlippageBps) updateSettings({ slippageBps: bps })
  }
  return (
    <div className="settings" role="dialog" aria-label="Trade settings">
      <div className="settings-row">
        <span>Slippage tolerance</span>
        <div className="chips">
          {PRESETS.map((p) => (
            <button key={p} className={settings.slippageBps === p && !custom ? 'on' : ''} onClick={() => { setCustom(''); updateSettings({ slippageBps: p }) }}>
              {p / 100}%
            </button>
          ))}
          <label className="chip-input">
            <input inputMode="decimal" placeholder="Custom" value={custom} onChange={(e) => setCustomPct(e.target.value)} aria-label="Custom slippage percent" />%
          </label>
        </div>
      </div>
      {settings.slippageBps > LIMITS.warnSlippageBps && (
        <p className="hint warn">A high tolerance lets bots take more from your trade. Use the lowest value that still goes through.</p>
      )}
      {custom && Math.round(Number(custom) * 100) > LIMITS.maxSlippageBps && <p className="hint bad">The maximum is {LIMITS.maxSlippageBps / 100}%.</p>}
      <div className="settings-row">
        <span>Transaction deadline</span>
        <label className="chip-input wide">
          <input inputMode="numeric" value={settings.deadlineMin} aria-label="Deadline in minutes"
            onChange={(e) => { const n = Number(e.target.value.replace(/\D/g, '')); if (n >= 1 && n <= 60) updateSettings({ deadlineMin: n }) }} /> minutes
        </label>
      </div>
      <div className="settings-row">
        <span>Token approvals</span>
        <div className="chips">
          <button className={!settings.unlimitedApproval ? 'on' : ''} onClick={() => updateSettings({ unlimitedApproval: false })}>Exact amount</button>
          <button className={settings.unlimitedApproval ? 'on' : ''} onClick={() => updateSettings({ unlimitedApproval: true })}>Unlimited</button>
        </div>
      </div>
      <p className="hint">Exact approvals cost one extra signature per trade but never leave spare allowance behind.</p>
      <button className="btn ghost" onClick={onClose}>Done</button>
    </div>
  )
}
