import { defineConfig } from "vite";

// exe（Electron）は file:// で開くので、読み込む場所は相対にする
export default defineConfig({
  base: "./",
  build: { outDir: "dist" },
});
