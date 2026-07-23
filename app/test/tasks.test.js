// Covers the task board API and the static UI landing page. Kept in a
// separate file from health.test.js (which covers /health and /api) so the
// two areas can be read and extended independently.
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const app = require('../index');

function request(server, method, path, body) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port,
        path,
        method,
        headers: payload
          ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
          : {},
      },
      (res) => {
        let raw = '';
        res.on('data', (chunk) => (raw += chunk));
        res.on('end', () => {
          const contentType = res.headers['content-type'] || '';
          const parsed = contentType.includes('application/json') && raw ? JSON.parse(raw) : raw;
          resolve({ status: res.statusCode, body: parsed });
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

test('GET / serves the task board UI', async () => {
  const server = app.listen(0);
  try {
    const { status, body } = await request(server, 'GET', '/');
    assert.strictEqual(status, 200);
    assert.ok(typeof body === 'string' && body.includes('DevOps Task Board'));
  } finally {
    server.close();
  }
});

test('GET /api/tasks returns the seeded task list', async () => {
  const server = app.listen(0);
  try {
    const { status, body } = await request(server, 'GET', '/api/tasks');
    assert.strictEqual(status, 200);
    assert.ok(Array.isArray(body.tasks));
    assert.ok(body.tasks.length > 0);
  } finally {
    server.close();
  }
});

test('POST /api/tasks creates a task, then it appears in the list', async () => {
  const server = app.listen(0);
  try {
    const created = await request(server, 'POST', '/api/tasks', { title: 'Write a test' });
    assert.strictEqual(created.status, 201);
    assert.strictEqual(created.body.task.title, 'Write a test');
    assert.strictEqual(created.body.task.done, false);

    const list = await request(server, 'GET', '/api/tasks');
    assert.ok(list.body.tasks.some((t) => t.id === created.body.task.id));
  } finally {
    server.close();
  }
});

test('POST /api/tasks rejects an empty title', async () => {
  const server = app.listen(0);
  try {
    const { status, body } = await request(server, 'POST', '/api/tasks', { title: '   ' });
    assert.strictEqual(status, 400);
    assert.ok(body.error);
  } finally {
    server.close();
  }
});

test('PATCH /api/tasks/:id toggles done, DELETE removes it', async () => {
  const server = app.listen(0);
  try {
    const created = await request(server, 'POST', '/api/tasks', { title: 'Toggle me' });
    const id = created.body.task.id;

    const patched = await request(server, 'PATCH', `/api/tasks/${id}`, { done: true });
    assert.strictEqual(patched.status, 200);
    assert.strictEqual(patched.body.task.done, true);

    const deleted = await request(server, 'DELETE', `/api/tasks/${id}`);
    assert.strictEqual(deleted.status, 204);

    const list = await request(server, 'GET', '/api/tasks');
    assert.ok(!list.body.tasks.some((t) => t.id === id));
  } finally {
    server.close();
  }
});

test('PATCH/DELETE on an unknown id return 404', async () => {
  const server = app.listen(0);
  try {
    const patched = await request(server, 'PATCH', '/api/tasks/does-not-exist', { done: true });
    assert.strictEqual(patched.status, 404);

    const deleted = await request(server, 'DELETE', '/api/tasks/does-not-exist');
    assert.strictEqual(deleted.status, 404);
  } finally {
    server.close();
  }
});
