import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.css'

// Refuse to run inside a frame (clickjacking defence in addition to the HTTP header).
if (window.top !== window.self) {
  document.body.textContent = 'DMDSwap can’t be displayed inside another site.'
} else {
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
}
