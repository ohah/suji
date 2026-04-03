const os = require('os');
const crypto = require('crypto');

function safeInvoke(backend, request) {
  try {
    return JSON.parse(suji.invoke(backend, request));
  } catch (e) {
    return { error: `invoke(${backend}) failed: ${e.message}` };
  }
}

// 기본 핸들러

suji.handle('node-ping', () => {
  return JSON.stringify({ msg: 'pong from Node.js!' });
});

suji.handle('node-greet', (data) => {
  const req = JSON.parse(data);
  const name = req.name || 'world';
  return JSON.stringify({ greeting: `Hello ${name} from Node.js!` });
});

// 런타임/시스템 정보

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

// 크로스 호출 (Node → 다른 백엔드)

for (const target of ['zig', 'rust', 'go']) {
  suji.handle(`node-call-${target}`, () => {
    const result = safeInvoke(target, '{"cmd":"ping"}');
    return JSON.stringify({ from: 'node', via: target, result });
  });
}

suji.handle('node-call-all', () => {
  const results = {};
  for (const target of ['zig', 'rust', 'go']) {
    results[target] = safeInvoke(target, '{"cmd":"ping"}');
  }
  return JSON.stringify({ from: 'node', results });
});

// 이벤트 발신 (Node → 프론트엔드)

suji.handle('node-emit-event', () => {
  suji.send('node-event', JSON.stringify({ msg: 'hello from Node.js!', time: Date.now() }));
  return JSON.stringify({ emitted: 'node-event' });
});

// Collab (Node leads — 다른 백엔드 협업)

suji.handle('node-collab', (data) => {
  const req = JSON.parse(data);
  const payload = req.data || 'node leads';

  const chain = {};
  for (const target of ['zig', 'rust', 'go']) {
    chain[target] = safeInvoke(target, JSON.stringify({ cmd: 'ping' }));
  }

  return JSON.stringify({ leader: 'node', payload, chain, timestamp: Date.now() });
});

suji.handle('node-chain-all', () => {
  const steps = [
    { backend: 'zig', cmd: 'greet', result: safeInvoke('zig', JSON.stringify({ cmd: 'greet', name: 'from Node' })) },
    { backend: 'rust', cmd: 'add', result: safeInvoke('rust', JSON.stringify({ cmd: 'add', a: 100, b: 200 })) },
    { backend: 'go', cmd: 'ping', result: safeInvoke('go', JSON.stringify({ cmd: 'ping' })) },
  ];
  return JSON.stringify({ chain: 'node→zig→rust→go', steps });
});

// 유틸리티

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
