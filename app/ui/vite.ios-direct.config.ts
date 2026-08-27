import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { resolve } from "path";

export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    // The finished page is one signed inline file. Omitting Vite's preload
    // polyfill also means the direct face bundle contains no fetch caller.
    modulePreload: false,
    // The character cues must remain inside that one signed page. Inlining
    // avoids adding a file/network fetch path to the media-only WebView.
    assetsInlineLimit: Infinity,
    outDir: "dist-ios-direct",
    emptyOutDir: true,
    rollupOptions: {
      input: resolve(import.meta.dirname, "ios-direct.html"),
    },
  },
});
