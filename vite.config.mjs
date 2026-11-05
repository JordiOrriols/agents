import path from "path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  server: { host: "127.0.0.1", port: 5179, strictPort: true },
  optimizeDeps: {
    exclude: [
      "@jordiorriols/ui",
      "@jordiorriols/ui/hooks",
      "@jordiorriols/ui/icons",
      "@jordiorriols/ui/radix",
    ],
  },
  plugins: [react(), tailwindcss()],
  resolve: {
    dedupe: ["react", "react-dom"],
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
});
