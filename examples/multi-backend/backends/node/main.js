suji.handle('node-ping', () => {
  return JSON.stringify({ msg: 'pong from Node.js!' });
});

suji.handle('node-greet', (data) => {
  const req = JSON.parse(data);
  const name = req.name || 'world';
  return JSON.stringify({ greeting: `Hello ${name} from Node.js!` });
});

suji.handle('node-info', () => {
  return JSON.stringify({
    runtime: 'Node.js',
    version: process.version,
    platform: process.platform,
    arch: process.arch
  });
});
