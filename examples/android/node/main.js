// Android embedded Node.js 백엔드 데모 — examples/android/node.
// suji.handle 로 등록한 채널을 호스트(nativeRegisterNodeBackend → suji_node_channels)
// 가 suji_core 에 배선 → WebView invoke 왕복. e2e.html(nodeSuite)이 자가검증.
// suji 전역은 libnode bridge(bridge.cc js_suji_handle)가 주입 — 데스크톱 node
// 백엔드 main.js 와 동형(data = {"cmd":channel,...} request 문자열).
suji.handle('ping', () => JSON.stringify({ runtime: 'node', msg: 'pong' }));

suji.handle('echo', (data) => {
  const req = JSON.parse(data);
  return JSON.stringify({ runtime: 'node', value: req.value, echo: req });
});
