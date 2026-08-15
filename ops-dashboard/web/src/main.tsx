import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@fontsource/ibm-plex-sans/400.css'
import '@fontsource/ibm-plex-sans/600.css'
import '@fontsource/ibm-plex-sans/700.css'
import '@fontsource/ibm-plex-mono/400.css'
import '@fontsource/ibm-plex-mono/500.css'
// Order is load-bearing: index.css pulls in tokens.css, then slate-tokens.css
// re-points the older token names at slate values (same :root specificity, so
// the later rule wins), then slate.css builds on the result.
import './index.css'
import './styles/slate-tokens.css'
import './styles/slate.css'
import App from './App.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
