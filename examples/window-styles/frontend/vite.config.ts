import { defineConfig } from "vite";

// 멀티 페이지: index.html (메인) / panel.html (frameless) / overlay.html (transparent HUD).
// vite dev mode는 자동으로 모두 서빙. build 시 rollupOptions.input에 명시.
export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        main: "index.html",
        panel: "panel.html",
        overlay: "overlay.html",
      },
    },
  },
});
