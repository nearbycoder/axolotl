#!/usr/bin/env node
// Axolotl sync relay.
//
// A zero-dependency HTTP server that stores end-to-end encrypted sync rows for Axolotl vaults.
// It never sees note contents: each row arrives as AES-GCM ciphertext plus an opaque per-field key
// (used to keep only the latest row per field) and the row's hybrid logical clock timestamp.
// Clients verify that the key and timestamp the server returns match the sealed row, so the
// relay cannot silently roll a field back to an older version.
//
//   PORT=8787 DATA_DIR=./data node server.mjs
//
// Environment:
//   REGISTRATION     open (default) or closed: whether unknown vaults may be created
//   MAX_VAULTS       vaults this relay will register (default 100)
//   MAX_VAULT_BYTES  storage allowed per vault, rows plus blobs (default 5 GiB)
//   MAX_BLOB_BYTES   largest single attachment (default 200 MiB)
//   TRUST_PROXY      1 to rate-limit by X-Forwarded-For (only behind your own reverse proxy)

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { DatabaseSync } from 'node:sqlite';

const VERSION = '1.2.0';
const MAX_PUSH_BYTES = 32 * 1024 * 1024;
const MAX_WAIT_SECONDS = 30;
const MAX_WAITERS_PER_VAULT = 64;
const REGISTRATIONS_PER_HOUR = 10;

export function createServer({
  dataDir = './data',
  registration = 'open',
  maxVaults = 100,
  maxVaultBytes = 5 * 1024 ** 3,
  maxBlobBytes = 200 * 1024 ** 2,
  trustProxy = false,
  log = () => {},
} = {}) {
  fs.mkdirSync(path.join(dataDir, 'blobs'), { recursive: true });
  const db = new DatabaseSync(path.join(dataDir, 'axolotl.sqlite'));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS vaults (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS changes (vault TEXT NOT NULL, key TEXT NOT NULL, hlc TEXT NOT NULL, data TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (vault, key));
    CREATE INDEX IF NOT EXISTS changes_seq ON changes (vault, seq);
  `);
  // Storage accounting was added in 1.2; older databases get the column with a recount.
  const columns = db.prepare('PRAGMA table_info(vaults)').all().map((c) => c.name);
  if (!columns.includes('bytes')) {
    db.exec('ALTER TABLE vaults ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0');
    db.exec('UPDATE vaults SET bytes = (SELECT COALESCE(SUM(LENGTH(data)), 0) FROM changes WHERE changes.vault = vaults.id)');
    for (const { id } of db.prepare('SELECT id FROM vaults').all()) {
      const dir = path.join(dataDir, 'blobs', id);
      if (!fs.existsSync(dir)) continue;
      let total = 0;
      for (const f of fs.readdirSync(dir)) total += fs.statSync(path.join(dir, f)).size;
      db.prepare('UPDATE vaults SET bytes = bytes + ? WHERE id = ?').run(total, id);
    }
  }

  const q = {
    vault: db.prepare('SELECT id, token_hash, seq, bytes FROM vaults WHERE id = ?'),
    vaultCount: db.prepare('SELECT COUNT(*) AS n FROM vaults'),
    createVault: db.prepare('INSERT INTO vaults (id, token_hash, seq, created, bytes) VALUES (?, ?, 0, ?, 0)'),
    bumpSeq: db.prepare('UPDATE vaults SET seq = seq + 1 WHERE id = ? RETURNING seq'),
    addBytes: db.prepare('UPDATE vaults SET bytes = MAX(0, bytes + ?) WHERE id = ?'),
    current: db.prepare('SELECT hlc, LENGTH(data) AS size FROM changes WHERE vault = ? AND key = ?'),
    upsert: db.prepare(`INSERT INTO changes (vault, key, hlc, data, seq) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (vault, key) DO UPDATE SET hlc = excluded.hlc, data = excluded.data, seq = excluded.seq`),
    pull: db.prepare('SELECT seq, key, hlc, data FROM changes WHERE vault = ? AND seq > ? ORDER BY seq LIMIT ?'),
  };

  /** vault id -> Set of callbacks waiting for new changes (long polling). */
  const waiters = new Map();
  function notify(vault) {
    const set = waiters.get(vault);
    if (!set) return;
    waiters.delete(vault);
    for (const fn of set) fn();
  }

  /** ip -> registration timestamps within the last hour. */
  const registrations = new Map();
  function registrationAllowed(ip) {
    const now = Date.now();
    const recent = (registrations.get(ip) || []).filter((t) => now - t < 3_600_000);
    if (recent.length >= REGISTRATIONS_PER_HOUR) return false;
    recent.push(now);
    registrations.set(ip, recent);
    if (registrations.size > 10_000) registrations.clear();
    return true;
  }

  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
  const isHex = (s, len) => typeof s === 'string' && s.length === len && /^[0-9a-f]+$/.test(s);
  const clientIp = (req) => (trustProxy && req.headers['x-forwarded-for']?.split(',')[0].trim()) || req.socket.remoteAddress || '?';

  function send(res, status, body, headers = {}) {
    const payload = body === undefined ? '' : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
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
      if (q.vaultCount.get().n >= maxVaults) return { error: [403, 'this relay is full'] };
      if (!registrationAllowed(clientIp(req))) return { error: [429, 'too many new vaults from this address'] };
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
        let bytes = q.vault.get(vault).bytes;
        for (const c of changes) {
          const cur = q.current.get(vault, c.k);
          // Last-writer-wins per field; equal timestamps are duplicates.
          if (cur && cur.hlc >= c.h) continue;
          const delta = Buffer.byteLength(c.d) - (cur ? cur.size : 0);
          if (bytes + delta > maxVaultBytes) {
            db.exec('ROLLBACK');
            return send(res, 413, { error: 'vault storage limit reached', bytes, limit: maxVaultBytes });
          }
          const { seq } = q.bumpSeq.get(vault);
          q.upsert.run(vault, c.k, c.h, c.d, seq);
          q.addBytes.run(delta, vault);
          bytes += delta;
          accepted++;
        }
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      const { seq, bytes } = q.vault.get(vault);
      if (accepted > 0) notify(vault);
      return send(res, 200, { accepted, cursor: seq, bytes, limit: maxVaultBytes });
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
        send(res, 200, { changes: page.map((r) => ({ s: r.seq, k: r.key, h: r.hlc, d: r.data })), cursor, more });
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
      const set = waiters.get(vault);
      if (set.size >= MAX_WAITERS_PER_VAULT) {
        // Too many open polls for one vault: answer the oldest one now.
        const oldest = set.values().next().value;
        oldest();
      }
      set.add(finish);
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
        let stat;
        try {
          stat = fs.statSync(file);
        } catch {
          return send(res, 404, req.method === 'HEAD' ? undefined : { error: 'no such blob' });
        }
        res.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Length': stat.size,
          'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
        });
        if (req.method === 'HEAD') return res.end();
        return pipeline(fs.createReadStream(file), res);
      }
      if (req.method === 'PUT') {
        const declared = parseInt(req.headers['content-length'] || '0', 10) || 0;
        const existing = fs.existsSync(file) ? fs.statSync(file).size : 0;
        const { bytes } = q.vault.get(vault);
        if (declared > maxBlobBytes) return send(res, 413, { error: 'attachment too large', limit: maxBlobBytes });
        if (bytes - existing + declared > maxVaultBytes) return send(res, 413, { error: 'vault storage limit reached', bytes, limit: maxVaultBytes });
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
        let size = 0;
        try {
          // Stream to disk so a large attachment never has to fit in memory.
          const out = fs.createWriteStream(tmp, { flags: 'wx' });
          await pipeline(
            req,
            async function* (source) {
              for await (const chunk of source) {
                size += chunk.length;
                if (size > maxBlobBytes || bytes - existing + size > maxVaultBytes) throw Object.assign(new Error('too large'), { status: 413 });
                yield chunk;
              }
            },
            out,
          );
          fs.renameSync(tmp, file);
        } catch (e) {
          fs.rmSync(tmp, { force: true });
          if (res.writableEnded) return;
          return send(res, e.status || 400, { error: e.status === 413 ? 'attachment too large' : 'upload failed' });
        }
        q.addBytes.run(size - existing, vault);
        return send(res, 200, { ok: true, size });
      }
    }

    return send(res, 404, { error: 'not found' });
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      log(`error: ${e.stack || e}`);
      if (!res.headersSent) send(res, 500, { error: 'internal error' });
      else res.destroy();
    });
  });
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 30_000;
  server.requestTimeout = 600_000; // large attachments on slow links; headersTimeout still bounds idle clients
  server.on('close', () => db.close());
  return server;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('server.mjs')) {
  const port = parseInt(process.env.PORT || '8787', 10);
  const host = process.env.HOST || '0.0.0.0';
  const registration = process.env.REGISTRATION || 'open';
  const server = createServer({
    dataDir: process.env.DATA_DIR || './data',
    registration,
    maxVaults: parseInt(process.env.MAX_VAULTS || '100', 10),
    maxVaultBytes: parseInt(process.env.MAX_VAULT_BYTES || String(5 * 1024 ** 3), 10),
    maxBlobBytes: parseInt(process.env.MAX_BLOB_BYTES || String(200 * 1024 ** 2), 10),
    trustProxy: process.env.TRUST_PROXY === '1',
    log: (m) => console.log(`[${new Date().toISOString()}] ${m}`),
  });
  server.listen(port, host, () => {
    console.log(`axolotl-sync ${VERSION} listening on http://${host}:${port}`);
    if (registration === 'open') console.log('registration is open; set REGISTRATION=closed once your devices have joined');
  });
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
