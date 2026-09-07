import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In development, /api is proxied to a local RAG API (or a port-forward to the cluster).
// In the container, nginx proxies /api to the rag-api Service.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      "/api": {
        target: process.env.VITE_API_PROXY ?? "http://localhost:8080",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
});
