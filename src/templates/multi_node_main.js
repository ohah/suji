// multi-backend: 채널을 백엔드별 네임스페이스로 충돌 회피 (zig 가 ping/greet 소유).
// target 없이 suji.invoke("node-ping") 으로 자동 라우팅된다.
const { handle } = require("@suji/node");

handle("node-ping", () => ({ from: "node", msg: "pong" }));

handle("node-greet", () => ({ from: "node", greeting: "Hello from Node.js!" }));
