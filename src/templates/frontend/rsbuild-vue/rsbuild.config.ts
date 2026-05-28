import { defineConfig } from "@rsbuild/core";
import { pluginVue } from "@rsbuild/plugin-vue";

export default defineConfig({
  plugins: [pluginVue()],
  source: { entry: { index: "./src/main.ts" } },
  html: { template: "./index.html" },
  server: { host: "127.0.0.1", port: 12300, strictPort: true },
});
