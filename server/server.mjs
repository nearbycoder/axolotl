#!/usr/bin/env node
// Axolotl sync relay.
//
// A zero-dependency HTTP server that stores end-to-end encrypted sync rows for Axolotl vaults.
// It never sees note contents: each row arrives as AES-GCM ciphertext plus an opaque per-field key
// (used to keep only the latest row per field) and the row's hybrid logical clock timestamp.
//
//   PORT=8787 DATA_DIR=./data node server.mjs

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const VERSION = '1.0.0';
const MAX_PUSH_BYTES = 64 * 1024 * 1024;
const MAX_BLOB_BYTES = 200 * 1024 * 1024;
const MAX_WAIT_SECONDS = 30;

export function createServer({ dataDir = './data', registration = 'open', log = () => {} } = {}) {
  fs.mkdirSync(path.join(dataDir, 'blobs'), { recursive: true });
  const db = new DatabaseSync(path.join(dataDir, 'axolotl.sqlite'));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS vaults (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS changes (vault TEXT NOT NULL, key TEXT NOT NULL, hlc TEXT NOT NULL, data TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (vault, key));
    CREATE INDEX IF NOT EXISTS changes_seq ON changes (vault, seq);
  `);

  const q = {
    vault: db.prepare('SELECT id, token_hash, seq FROM vaults WHERE id = ?'),
    createVault: db.prepare('INSERT INTO vaults (id, token_hash, seq, created) VALUES (?, ?, 0, ?)'),
    bumpSeq: db.prepare('UPDATE vaults SET seq = seq + 1 WHERE id = ? RETURNING seq'),
    current: db.prepare('SELECT hlc FROM changes WHERE vault = ? AND key = ?'),
    upsert: db.prepare(`INSERT INTO changes (vault, key, hlc, data, seq) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (vault, key) DO UPDATE SET hlc = excluded.hlc, data = excluded.data, seq = excluded.seq`),
    pull: db.prepare('SELECT seq, data FROM changes WHERE vault = ? AND seq > ? ORDER BY seq LIMIT ?'),
    stats: db.prepare('SELECT COUNT(*) AS vaults FROM vaults'),
  };

  /** vault id -> Set of callbacks waiting for new changes (long polling). */
  const waiters = new Map();
  function notify(vault) {
    const set = waiters.get(vault);
    if (!set) return;
    waiters.delete(vault);
    for (const fn of set) fn();
  }

  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
  const isHex = (s, len) => typeof s === 'string' && s.length === len && /^[0-9a-f]+$/.test(s);

  function send(res, status, body, headers = {}) {
    const isBuffer = Buffer.isBuffer(body);
    const payload = body === undefined ? '' : isBuffer ? body : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': isBuffer ? 'application/octet-stream' : 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      'Cache-Control': 'no-store',
      ...headers,
    });
    res.end(payload);
  }

  function readBody(req, limit) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on('data', (c) => {
        size += c.length;
        if (size > limit) {
          reject(Object.assign(new Error('payload too large'), { status: 413 }));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', reject);
    });
  }

  /** Authenticates a request. Unknown vaults are registered on first use with their token. */
  function authorize(req, vaultId) {
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!isHex(token, 64)) return { error: [401, 'missing or malformed token'] };
    const hash = sha256(token);
    const vault = q.vault.get(vaultId);
    if (!vault) {
      if (registration !== 'open') return { error: [403, 'registration closed'] };
      q.createVault.run(vaultId, hash, Date.now());
      log(`registered vault ${vaultId.slice(0, 8)}…`);
      return { ok: true };
    }
    const a = Buffer.from(vault.token_hash), b = Buffer.from(hash);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return { error: [403, 'invalid token'] };
    return { ok: true };
  }

  function blobPath(vault, key) {
    return path.join(dataDir, 'blobs', vault, key);
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/v1/health') {
      return send(res, 200, { ok: true, service: 'axolotl-sync', version: VERSION });
    }
    if (req.method === 'GET' && url.pathname === '/') {
      return send(res, 200, { service: 'axolotl-sync', version: VERSION, docs: 'https://nearbycoder.github.io/axolotl/#sync' });
    }
    if (parts[0] !== 'v1' || parts[1] !== 'vaults' || !isHex(parts[2], 32)) {
      return send(res, 404, { error: 'not found' });
    }
    const vault = parts[2];
    const auth = authorize(req, vault);
    if (auth.error) return send(res, auth.error[0], { error: auth.error[1] });

    // POST /v1/vaults/:vault/push  { changes: [{ k, h, d }] }
    if (req.method === 'POST' && parts[3] === 'push' && parts.length === 4) {
      let body;
      try {
        body = JSON.parse((await readBody(req, MAX_PUSH_BYTES)).toString('utf8'));
      } catch (e) {
        return send(res, e.status || 400, { error: e.message });
      }
      const changes = Array.isArray(body?.changes) ? body.changes : null;
      if (!changes) return send(res, 400, { error: 'changes must be an array' });
      for (const c of changes) {
        if (!isHex(c?.k, 32) || typeof c.h !== 'string' || c.h.length > 80 || typeof c.d !== 'string') {
          return send(res, 400, { error: 'malformed change' });
        }
      }
      let accepted = 0;
      db.exec('BEGIN IMMEDIATE');
      try {
        for (const c of changes) {
          const cur = q.current.get(vault, c.k);
          // Last-writer-wins per field; equal timestamps are duplicates.
          if (cur && cur.hlc >= c.h) continue;
          const { seq } = q.bumpSeq.get(vault);
          q.upsert.run(vault, c.k, c.h, c.d, seq);
          accepted++;
        }
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      const { seq } = q.vault.get(vault);
      if (accepted > 0) notify(vault);
      return send(res, 200, { accepted, cursor: seq });
    }

    // GET /v1/vaults/:vault/pull?since=0&limit=500&wait=25
    if (req.method === 'GET' && parts[3] === 'pull' && parts.length === 4) {
      const since = Math.max(0, parseInt(url.searchParams.get('since') || '0', 10) || 0);
      const limit = Math.min(2000, Math.max(1, parseInt(url.searchParams.get('limit') || '500', 10) || 500));
      const wait = Math.min(MAX_WAIT_SECONDS, Math.max(0, parseInt(url.searchParams.get('wait') || '0', 10) || 0));
      const respond = () => {
        // A cursor ahead of the server (e.g. the server was reset) restarts from the beginning.
        const from = since > q.vault.get(vault).seq ? 0 : since;
        const rows = q.pull.all(vault, from, limit + 1);
        const more = rows.length > limit;
        const page = rows.slice(0, limit);
        const cursor = page.length ? page[page.length - 1].seq : from;
        send(res, 200, { changes: page.map((r) => ({ s: r.seq, d: r.data })), cursor, more });
      };
      if (wait === 0 || q.vault.get(vault).seq !== since) return respond();
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        waiters.get(vault)?.delete(finish);
        if (!res.writableEnded && !res.destroyed) respond();
      };
      const timer = setTimeout(finish, wait * 1000);
      if (!waiters.has(vault)) waiters.set(vault, new Set());
      waiters.get(vault).add(finish);
      req.on('close', () => {
        done = true;
        clearTimeout(timer);
        waiters.get(vault)?.delete(finish);
      });
      return;
    }

    // HEAD|GET|PUT /v1/vaults/:vault/blobs/:key
    if (parts[3] === 'blobs' && parts.length === 5 && isHex(parts[4], 32)) {
      const file = blobPath(vault, parts[4]);
      if (req.method === 'HEAD' || req.method === 'GET') {
        if (!fs.existsSync(file)) return send(res, 404, req.method === 'HEAD' ? undefined : { error: 'no such blob' });
        if (req.method === 'HEAD') {
          res.writeHead(200, { 'Content-Length': fs.statSync(file).size });
          return res.end();
        }
        return send(res, 200, fs.readFileSync(file));
      }
      if (req.method === 'PUT') {
        let data;
        try {
          data = await readBody(req, MAX_BLOB_BYTES);
        } catch (e) {
          return send(res, e.status || 400, { error: e.message });
        }
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
        fs.writeFileSync(tmp, data);
        fs.renameSync(tmp, file);
        return send(res, 200, { ok: true, size: data.length });
      }
    }

    return send(res, 404, { error: 'not found' });
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      log(`error: ${e.stack || e}`);
      if (!res.headersSent) send(res, 500, { error: 'internal error' });
    });
  });
  server.keepAliveTimeout = 65_000;
  server.requestTimeout = 0;
  server.on('close', () => db.close());
  return server;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('server.mjs')) {
  const port = parseInt(process.env.PORT || '8787', 10);
  const host = process.env.HOST || '0.0.0.0';
  const server = createServer({
    dataDir: process.env.DATA_DIR || './data',
    registration: process.env.REGISTRATION || 'open',
    log: (m) => console.log(`[${new Date().toISOString()}] ${m}`),
  });
  server.listen(port, host, () => console.log(`axolotl-sync ${VERSION} listening on http://${host}:${port}`));
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
