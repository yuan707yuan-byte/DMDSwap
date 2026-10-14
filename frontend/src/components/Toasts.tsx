import { EXPLORER_URL } from '../lib/config'
import { useApp } from '../store'

export function Toasts() {
  const { toasts, dismissToast } = useApp()
  return (
    <div className="toasts" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast toast-${t.status}`}>
          <div className="toast-head">
            <span className="toast-dot" aria-hidden="true" />
            <strong>{t.title}</strong>
            <button onClick={() => dismissToast(t.id)} aria-label="Dismiss">×</button>
          </div>
          {t.body && <p>{t.body}</p>}
          {t.hash && <a className="link" href={`${EXPLORER_URL}/tx/${t.hash}`} target="_blank" rel="noreferrer noopener">View transaction</a>}
        </div>
      ))}
    </div>
  )
}
