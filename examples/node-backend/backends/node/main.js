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
