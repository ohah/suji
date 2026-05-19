import { defineConfig } from "vite";

// suji dev 가 frontend.dev_url(기본 5173)로 이 서버를 띄운다.
export default defineConfig({
  server: { port: 5173, strictPort: true },
});
