const express = require('express');
const path = require('path');
const pool = require('./db');
const { validateTitle } = require('./validate');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

// Liveness: is the Node process alive? (DB check nahi - DB down asel tar pod restart nako)
app.get('/health', (req, res) => res.json({ status: 'UP' }));

// Readiness: can we talk to the DB? (DB nasel tar traffic band)
app.get('/health/ready', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'READY' });
  } catch (e) {
    res.status(503).json({ status: 'NOT_READY', error: e.code || e.message });
  }
});

app.get('/api/tasks', async (req, res) => {
  try {
    const [rows] = await pool.query('SELECT id, title, created_at FROM tasks ORDER BY id DESC');
    res.json(rows);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'db error' });
  }
});

app.post('/api/tasks', async (req, res) => {
  const v = validateTitle(req.body && req.body.title);
  if (!v.ok) return res.status(400).json({ error: v.error });
  try {
    const [r] = await pool.query('INSERT INTO tasks (title) VALUES (?)', [v.value]);
    res.status(201).json({ id: r.insertId, title: v.value });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'db error' });
  }
});

app.delete('/api/tasks/:id', async (req, res) => {
  try {
    await pool.query('DELETE FROM tasks WHERE id = ?', [Number(req.params.id)]);
    res.status(204).end();
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'db error' });
  }
});

// Shows which pod served the request - useful to demo load-balancing
app.get('/api/info', (req, res) => res.json({ pod: process.env.HOSTNAME, version: process.env.APP_VERSION || 'dev' }));

const port = process.env.PORT || 3000;
const server = app.listen(port, () => console.log(`App listening on ${port}`));

// Graceful shutdown (Kubernetes SIGTERM pathavto)
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down');
  server.close(async () => { await pool.end(); process.exit(0); });
});
