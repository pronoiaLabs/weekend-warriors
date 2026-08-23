import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// tokens first (the Prism palette and type scale), then the primitives built on them.
import './styles/tokens.css'
import './styles/sports.css'
import './styles/pages.css'
import App from './App.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
