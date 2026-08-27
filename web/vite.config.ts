import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("/node_modules/firebase/")) return undefined
          if (id.includes("/auth/") || id.includes("/app-check/")) return "firebase-auth"
          if (
            id.includes("/firestore/") ||
            id.includes("/functions/") ||
            id.includes("/storage/")
          ) return "firebase-data"
          return "firebase-core"
        },
      },
    },
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
})
