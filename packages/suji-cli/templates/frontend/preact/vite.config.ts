import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// suji dev 가 frontend.dev_url(기본 5173)로 이 서버를 띄운다.
export default defineConfig({
  plugins: [preact()],
  server: { port: 5173, strictPort: true },
});
