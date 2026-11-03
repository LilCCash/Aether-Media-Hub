import { defineConfig } from "vite";

// base "./": the site lives under a project path on GitHub Pages (…/Aether-Media-Hub/), so every address is relative.
export default defineConfig({
  base: "./",
  build: { target: "es2022", sourcemap: false },
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
