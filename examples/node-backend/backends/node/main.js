const os = require('os');
const crypto = require('crypto');

suji.handle('ping', () => {
  return JSON.stringify({ msg: 'pong' });
});

suji.handle('greet', (data) => {
  const req = JSON.parse(data);
  const name = req.name || 'world';
  return JSON.stringify({ msg: name, greeting: 'Hello from Node.js!' });
});

suji.handle('add', (data) => {
  const req = JSON.parse(data);
  const a = req.a || 0;
  const b = req.b || 0;
  return JSON.stringify({ result: a + b });
});

suji.handle('info', () => {
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

suji.handle('system', () => {
  return JSON.stringify({
    hostname: os.hostname(),
    cpus: os.cpus().length,
    totalMemory: `${(os.totalmem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
    freeMemory: `${(os.freemem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
    osType: `${os.type()} ${os.release()}`
  });
});

suji.handle('hash', (data) => {
  const req = JSON.parse(data);
  const text = req.text || 'hello suji';
  return JSON.stringify({
    input: text,
    md5: crypto.createHash('md5').update(text).digest('hex'),
    sha256: crypto.createHash('sha256').update(text).digest('hex').slice(0, 16) + '...',
    uuid: crypto.randomUUID()
  });
});
