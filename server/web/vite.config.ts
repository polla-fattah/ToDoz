import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// NoteDo for the web. The server serves the build at /app (see ../lib/web.dart), so every asset address starts with
// /app/. `npm run dev` runs the page on its own port and passes the API calls to a server on 127.0.0.1:18099.
export default defineConfig({
  base: '/app/',
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true, assetsInlineLimit: 0, sourcemap: false },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:18099',
      '/web': 'http://127.0.0.1:18099',
    },
  },
});
