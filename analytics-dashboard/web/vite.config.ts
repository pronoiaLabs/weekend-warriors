import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Own ports, so this app and ops-dashboard run side by side: the API on 8010,
// this dev server on 5174 proxying /api to it.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5174,
    proxy: {
      '/api': 'http://127.0.0.1:8010',
    },
  },
})
