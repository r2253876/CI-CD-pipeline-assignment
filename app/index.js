const path = require('path');
const crypto = require('crypto');
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;
const APP_ENV = process.env.APP_ENV || 'development';
const APP_VERSION = process.env.APP_VERSION || 'dev';

// Simulated "config" that would normally come from a ConfigMap / env vars
const config = {
  featureFlagBeta: process.env.FEATURE_FLAG_BETA === 'true',
  greeting: process.env.APP_GREETING || 'Hello from the DevOps sample API',
};

// Simulated "secret" — in a real deployment this is injected from a
// Kubernetes Secret (backed by AWS Secrets Manager / SSM Parameter Store
// via External Secrets Operator, see README). We only ever expose a
// redacted/derived value, never the raw secret.
const apiKey = process.env.API_KEY || 'mock-secret-not-set';

app.use(express.json());

/**
 * Liveness/readiness probe target.
 * Kept intentionally dependency-free so Kubernetes can determine pod
 * health without relying on downstream services (including the in-memory
 * task store below) being up.
 */
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    env: APP_ENV,
    version: APP_VERSION,
    uptimeSeconds: process.uptime(),
  });
});

/**
 * Deployment-info endpoint. This is what the UI's status banner calls to
 * prove the ConfigMap and Secret are actually reaching the container as
 * environment variables, rather than just being defined in Helm values.
 */
app.get('/api', (req, res) => {
  res.status(200).json({
    message: config.greeting,
    env: APP_ENV,
    version: APP_VERSION,
    featureFlagBeta: config.featureFlagBeta,
    secretConfigured: apiKey !== 'mock-secret-not-set',
  });
});

// ---------------------------------------------------------------------
// Task board — the "real" feature this sample app demonstrates. Deliberately
// in-memory (no database dependency to stand up for a CI/CD exercise): data
// resets on every pod restart/rollout, which is fine here since the point
// is to give the pipeline something with actual read/write behavior to
// build, test, and deploy — not to be a production task tracker. Swapping
// this for a real datastore would only touch this block; the routes below
// and the UI in public/ would not need to change.
// ---------------------------------------------------------------------
let tasks = [
  { id: crypto.randomUUID(), title: 'Wire up the Jenkins pipeline', done: true, createdAt: new Date().toISOString() },
  { id: crypto.randomUUID(), title: 'Deploy to EKS behind an ALB', done: true, createdAt: new Date().toISOString() },
  { id: crypto.randomUUID(), title: 'Add SonarQube, scanning, and signing', done: !!config.featureFlagBeta, createdAt: new Date().toISOString() },
  { id: crypto.randomUUID(), title: 'Watch the HPA scale under load', done: false, createdAt: new Date().toISOString() },
];

app.get('/api/tasks', (req, res) => {
  res.status(200).json({ tasks });
});

app.post('/api/tasks', (req, res) => {
  const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
  if (!title) {
    return res.status(400).json({ error: 'title is required' });
  }
  if (title.length > 200) {
    return res.status(400).json({ error: 'title must be 200 characters or fewer' });
  }
  const task = { id: crypto.randomUUID(), title, done: false, createdAt: new Date().toISOString() };
  tasks.push(task);
  res.status(201).json({ task });
});

app.patch('/api/tasks/:id', (req, res) => {
  const task = tasks.find((t) => t.id === req.params.id);
  if (!task) {
    return res.status(404).json({ error: 'task not found' });
  }
  if (typeof req.body?.done === 'boolean') {
    task.done = req.body.done;
  }
  if (typeof req.body?.title === 'string' && req.body.title.trim()) {
    task.title = req.body.title.trim().slice(0, 200);
  }
  res.status(200).json({ task });
});

app.delete('/api/tasks/:id', (req, res) => {
  const before = tasks.length;
  tasks = tasks.filter((t) => t.id !== req.params.id);
  if (tasks.length === before) {
    return res.status(404).json({ error: 'task not found' });
  }
  res.status(204).end();
});

// Static UI (public/index.html + style.css + app.js). express.static
// serves index.html for GET / automatically, so no explicit route is
// needed for the landing page itself.
app.use(express.static(path.join(__dirname, 'public')));

// Only start listening when run directly (keeps the app importable for tests)
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`devops-sample-api listening on port ${PORT} [env=${APP_ENV}, version=${APP_VERSION}]`);
  });
}

module.exports = app;
