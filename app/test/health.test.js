// Minimal unit tests using Node's built-in test runner (node --test),
// so the pipeline needs no extra test framework dependency.
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const app = require('../index');

function request(server, path) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    http.get(`http://127.0.0.1:${port}${path}`, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(body) }));
    }).on('error', reject);
  });
}

test('GET /health returns 200 and status ok', async () => {
  const server = app.listen(0);
  try {
    const { status, body } = await request(server, '/health');
    assert.strictEqual(status, 200);
    assert.strictEqual(body.status, 'ok');
  } finally {
    server.close();
  }
});

test('GET /api returns 200 and a message', async () => {
  const server = app.listen(0);
  try {
    const { status, body } = await request(server, '/api');
    assert.strictEqual(status, 200);
    assert.ok(typeof body.message === 'string' && body.message.length > 0);
  } finally {
    server.close();
  }
});
