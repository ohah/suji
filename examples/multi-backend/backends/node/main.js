const { handle, invokeSync, send } = require('@suji/node');
const os = require('os');
const crypto = require('crypto');

function safeInvoke(backend, request) {
  try {
    return invokeSync(backend, request);
  } catch (e) {
    return { error: `invoke(${backend}) failed: ${e.message}` };
  }
}

// 기본 핸들러

handle('node-ping', () => ({ msg: 'pong from Node.js!' }));

handle('node-greet', (data) => ({
  greeting: `Hello ${data.name || 'world'} from Node.js!`
}));

// 런타임/시스템 정보

handle('node-info', () => ({
  runtime: 'Node.js',
  version: process.version,
  platform: process.platform,
  arch: process.arch,
  pid: process.pid,
  uptime: `${process.uptime().toFixed(1)}s`,
  memory: `${(process.memoryUsage().heapUsed / 1024 / 1024).toFixed(1)}MB`
}));

handle('node-system', () => ({
  hostname: os.hostname(),
  cpus: os.cpus().length,
  totalMemory: `${(os.totalmem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
  freeMemory: `${(os.freemem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
  osType: `${os.type()} ${os.release()}`
}));

// 크로스 호출 (Node → 다른 백엔드)

for (const target of ['zig', 'rust', 'go']) {
  handle(`node-call-${target}`, () => ({
    from: 'node', via: target, result: safeInvoke(target, { cmd: 'ping' })
  }));
}

handle('node-call-all', () => {
  const results = {};
  for (const target of ['zig', 'rust', 'go']) {
    results[target] = safeInvoke(target, { cmd: 'ping' });
  }
  return { from: 'node', results };
});

// 이벤트 발신

handle('node-emit-event', () => {
  send('node-event', { msg: 'hello from Node.js!', time: Date.now() });
  return { emitted: 'node-event' };
});

// Collab

handle('node-collab', (data) => {
  const payload = data.data || 'node leads';
  const chain = {};
  for (const target of ['zig', 'rust', 'go']) {
    chain[target] = safeInvoke(target, { cmd: 'ping' });
  }
  return { leader: 'node', payload, chain, timestamp: Date.now() };
});

handle('node-chain-all', () => {
  const steps = [
    { backend: 'zig', cmd: 'greet', result: safeInvoke('zig', { cmd: 'greet', name: 'from Node' }) },
    { backend: 'rust', cmd: 'add', result: safeInvoke('rust', { cmd: 'add', a: 100, b: 200 }) },
    { backend: 'go', cmd: 'ping', result: safeInvoke('go', { cmd: 'ping' }) },
  ];
  return { chain: 'node→zig→rust→go', steps };
});

// 유틸리티

// 기술 부채 C 재현: Node main thread가 invokeSync로 block 중일 때
// 다른 OS 스레드에서 Node 재진입 invoke가 들어오면 queue는 쌓이지만 drain되지 않아 timeout.
// 체인: JS → Node(invokeSync "rust") → Rust → std::thread → Node(재진입)
handle('node-thread-deadlock', () => {
  return { result: safeInvoke('rust', { cmd: 'rust-thread-node' }) };
});

// 스트레스 테스트: 재귀 크로스 호출 체인
// 체인: node -> zig -> rust -> go -> node -> ... (4주기 반복)
// depth를 1씩 감소하다 0이 되면 base 반환.
handle('node-stress', (data) => {
  const depth = data.depth | 0;
  if (depth <= 0) {
    return { base: 'node', remaining: 0 };
  }
  // node 다음은 zig
  const child = safeInvoke('zig', { cmd: 'zig-stress', depth: depth - 1 });
  return { at: 'node', child };
});

handle('node-hash', (data) => {
  const text = data.text || 'hello suji';
  return {
    input: text,
    md5: crypto.createHash('md5').update(text).digest('hex'),
    sha256: crypto.createHash('sha256').update(text).digest('hex').slice(0, 16) + '...',
    uuid: crypto.randomUUID()
  };
});
