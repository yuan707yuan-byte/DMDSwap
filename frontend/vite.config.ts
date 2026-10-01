import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'

// Strict Content-Security-Policy injected into the PRODUCTION build only (dev needs HMR websockets).
// The page may only talk to itself and the DMD RPC; no third-party scripts, fonts, images or frames.
// Also set `frame-ancestors 'none'` + `X-Frame-Options: DENY` as HTTP headers on your host (see README).
const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self' https://rpc.bit.diamonds",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  'upgrade-insecure-requests',
].join('; ')

function cspPlugin(): Plugin {
  return {
    name: 'dmdswap-csp',
    apply: 'build',
    transformIndexHtml(html) {
      return html.replace('<!--CSP-->', `<meta http-equiv="Content-Security-Policy" content="${CSP}" />`)
    },
  }
}

export default defineConfig({
  plugins: [react(), cspPlugin()],
  build: { sourcemap: false, target: 'es2022', assetsInlineLimit: 0 },
  server: { port: 5173 },
})
