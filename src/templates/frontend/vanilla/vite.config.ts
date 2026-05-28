import { defineConfig } from "vite";

// suji dev 가 frontend.dev_url(기본 12300)로 이 서버를 띄운다.
export default defineConfig({
  server: { host: "127.0.0.1", port: 12300, strictPort: true },
});
