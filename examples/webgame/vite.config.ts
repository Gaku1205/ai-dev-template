import { defineConfig } from "vite";

// どこに置いても読めるよう、読み込む場所は相対にする
export default defineConfig({
  base: "./",
  build: { outDir: "dist" },
});
