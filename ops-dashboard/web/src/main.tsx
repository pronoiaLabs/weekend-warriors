import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// tokens first (every colour), then the shared primitives, then the
// investigation components, then page layouts; each only references tokens
import './styles/tokens.css'
import './styles/ops.css'
import './styles/components.css'
import './styles/pages.css'
import App from './App.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
