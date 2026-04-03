const os = require('os');
const crypto = require('crypto');

// ============================================
// 기본 핸들러
// ============================================

suji.handle('node-ping', () => {
  return JSON.stringify({ msg: 'pong from Node.js!' });
});

suji.handle('node-greet', (data) => {
  const req = JSON.parse(data);
  const name = req.name || 'world';
  return JSON.stringify({ greeting: `Hello ${name} from Node.js!` });
});

// ============================================
// 런타임/시스템 정보 (Node.js 강점)
// ============================================

suji.handle('node-info', () => {
  return JSON.stringify({
    runtime: 'Node.js',
    version: process.version,
    platform: process.platform,
    arch: process.arch,
    pid: process.pid,
    uptime: `${process.uptime().toFixed(1)}s`,
    memory: `${(process.memoryUsage().heapUsed / 1024 / 1024).toFixed(1)}MB`
  });
});

suji.handle('node-system', () => {
  return JSON.stringify({
    hostname: os.hostname(),
    cpus: os.cpus().length,
    totalMemory: `${(os.totalmem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
    freeMemory: `${(os.freemem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
    osType: `${os.type()} ${os.release()}`
  });
});

// ============================================
// 크로스 호출 (Node → 다른 백엔드)
// ============================================

suji.handle('node-call-zig', () => {
  const result = suji.invoke('zig', '{"cmd":"ping"}');
  return JSON.stringify({ from: 'node', via: 'zig', result: JSON.parse(result) });
});

suji.handle('node-call-rust', () => {
  const result = suji.invoke('rust', '{"cmd":"ping"}');
  return JSON.stringify({ from: 'node', via: 'rust', result: JSON.parse(result) });
});

suji.handle('node-call-go', () => {
  const result = suji.invoke('go', '{"cmd":"ping"}');
  return JSON.stringify({ from: 'node', via: 'go', result: JSON.parse(result) });
});

suji.handle('node-call-all', () => {
  const zig = JSON.parse(suji.invoke('zig', '{"cmd":"ping"}'));
  const rust = JSON.parse(suji.invoke('rust', '{"cmd":"ping"}'));
  const go = JSON.parse(suji.invoke('go', '{"cmd":"ping"}'));
  return JSON.stringify({ from: 'node', results: { zig, rust, go } });
});

// ============================================
// 이벤트 발신 (Node → 프론트엔드)
// ============================================

suji.handle('node-emit-event', () => {
  suji.send('node-event', JSON.stringify({ msg: 'hello from Node.js!', time: Date.now() }));
  return JSON.stringify({ emitted: 'node-event' });
});

// ============================================
// 유틸리티 (crypto, JSON 변환)
// ============================================

// ============================================
// Collab (Node leads — 다른 백엔드 협업)
// ============================================

suji.handle('node-collab', (data) => {
  const req = JSON.parse(data);
  const payload = req.data || 'node leads';

  // Node → Zig → Rust → Go 순서로 협업
  const zigResult = JSON.parse(suji.invoke('zig', JSON.stringify({ cmd: 'ping' })));
  const rustResult = JSON.parse(suji.invoke('rust', JSON.stringify({ cmd: 'ping' })));
  const goResult = JSON.parse(suji.invoke('go', JSON.stringify({ cmd: 'ping' })));

  return JSON.stringify({
    leader: 'node',
    payload,
    chain: { zig: zigResult, rust: rustResult, go: goResult },
    timestamp: Date.now()
  });
});

suji.handle('node-chain-all', () => {
  // Node → Zig(greet) → Rust(add) → Go(ping) 체인
  const step1 = JSON.parse(suji.invoke('zig', JSON.stringify({ cmd: 'greet', name: 'from Node' })));
  const step2 = JSON.parse(suji.invoke('rust', JSON.stringify({ cmd: 'add', a: 100, b: 200 })));
  const step3 = JSON.parse(suji.invoke('go', JSON.stringify({ cmd: 'ping' })));

  return JSON.stringify({
    chain: 'node→zig→rust→go',
    steps: [
      { backend: 'zig', cmd: 'greet', result: step1 },
      { backend: 'rust', cmd: 'add', result: step2 },
      { backend: 'go', cmd: 'ping', result: step3 }
    ]
  });
});

// ============================================
// 유틸리티 (crypto, JSON 변환)
// ============================================

suji.handle('node-hash', (data) => {
  const req = JSON.parse(data);
  const text = req.text || 'hello suji';
  return JSON.stringify({
    input: text,
    md5: crypto.createHash('md5').update(text).digest('hex'),
    sha256: crypto.createHash('sha256').update(text).digest('hex').slice(0, 16) + '...',
    uuid: crypto.randomUUID()
  });
});
