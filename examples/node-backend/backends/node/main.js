const { handle, send } = require('@suji/node');
const os = require('os');
const crypto = require('crypto');

handle('ping', () => ({ msg: 'pong' }));

handle('greet', (data) => ({
  msg: data.name || 'world',
  greeting: 'Hello from Node.js!'
}));

handle('add', (data) => ({
  result: (data.a || 0) + (data.b || 0)
}));

handle('info', () => ({
  runtime: 'Node.js',
  version: process.version,
  platform: process.platform,
  arch: process.arch,
  pid: process.pid,
  uptime: `${process.uptime().toFixed(1)}s`,
  memory: `${(process.memoryUsage().heapUsed / 1024 / 1024).toFixed(1)}MB`
}));

handle('system', () => ({
  hostname: os.hostname(),
  cpus: os.cpus().length,
  totalMemory: `${(os.totalmem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
  freeMemory: `${(os.freemem() / 1024 / 1024 / 1024).toFixed(1)}GB`,
  osType: `${os.type()} ${os.release()}`
}));

handle('hash', (data) => {
  const text = data.text || 'hello suji';
  return {
    input: text,
    md5: crypto.createHash('md5').update(text).digest('hex'),
    sha256: crypto.createHash('sha256').update(text).digest('hex').slice(0, 16) + '...',
    uuid: crypto.randomUUID()
  };
});
