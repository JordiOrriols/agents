import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "path";

export default defineConfig({
  plugins: [react()],
  resolve: {
    dedupe: ["react", "react-dom"],
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "jsdom",
    // Use jsdom's browser storage instead of Node's file-backed Web Storage.
    execArgv: ["--no-experimental-webstorage"],
    globals: true,
    setupFiles: ["src/setupTests.ts"],
    include: ["src/**/*.{test,spec}.{js,mjs,cjs,ts,mts,cts,jsx,tsx}"],
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
      include: ["src/**/*.{js,ts,jsx,tsx}"],
      exclude: ["**/node_modules/**", "src/index.*", "src/**/__tests__/**", "src/**/*.test.*"],
      statements: 80,
      branches: 80,
      functions: 80,
      lines: 80,
    },
  },
});
