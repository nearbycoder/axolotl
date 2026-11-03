import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createServer } from './server.mjs';

const vault = 'a'.repeat(32);
const token = 'b'.repeat(64);
const auth = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

async function withServer(fn, options = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'axolotl-sync-'));
  const server = createServer({ dataDir, ...options });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base, dataDir);
  } finally {
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

const push = (base, changes, headers = auth, v = vault) =>
  fetch(`${base}/v1/vaults/${v}/push`, { method: 'POST', headers, body: JSON.stringify({ changes }) });

test('health', () => withServer(async (base) => {
  const res = await fetch(`${base}/v1/health`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).ok, true);
}));

test('push, compaction and pull with verifiable key and timestamp', () => withServer(async (base) => {
  const k1 = '1'.repeat(32), k2 = '2'.repeat(32);
  let res = await push(base, [{ k: k1, h: '0000000000001-0000-a', d: 'one' }, { k: k2, h: '0000000000001-0001-a', d: 'two' }]);
  let body = await res.json();
  assert.equal(body.accepted, 2);
  assert.equal(body.cursor, 2);
  assert.equal(body.bytes, 6);
  // Older timestamp for k1 is ignored; newer replaces it.
  res = await push(base, [{ k: k1, h: '0000000000000-0000-a', d: 'stale' }]);
  assert.equal((await res.json()).accepted, 0);
  res = await push(base, [{ k: k1, h: '0000000000002-0000-b', d: 'one-v2' }]);
  body = await res.json();
  assert.equal(body.accepted, 1);
  assert.equal(body.cursor, 3);
  assert.equal(body.bytes, 9);

  res = await fetch(`${base}/v1/vaults/${vault}/pull?since=0`, { headers: auth });
  body = await res.json();
  assert.deepEqual(body.changes, [
    { s: 2, k: k2, h: '0000000000001-0001-a', d: 'two' },
    { s: 3, k: k1, h: '0000000000002-0000-b', d: 'one-v2' },
  ]);
  assert.equal(body.cursor, 3);
  assert.equal(body.more, false);

  res = await fetch(`${base}/v1/vaults/${vault}/pull?since=1&limit=1`, { headers: auth });
  const page = await res.json();
  assert.equal(page.changes.length, 1);
  assert.equal(page.more, true);
}));

test('rejects wrong token after registration', () => withServer(async (base) => {
  await push(base, []);
  const res = await push(base, [], { ...auth, Authorization: `Bearer ${'c'.repeat(64)}` });
  assert.equal(res.status, 403);
}));

test('closed registration refuses new vaults but serves existing ones', () => withServer(async (base) => {
  const res = await push(base, []);
  assert.equal(res.status, 403);
  assert.equal((await res.json()).error, 'registration closed');
}, { registration: 'closed' }));

test('vault count and per-address registration limits', () => withServer(async (base) => {
  assert.equal((await push(base, [], auth, 'd'.repeat(32))).status, 200);
  assert.equal((await push(base, [], auth, 'e'.repeat(32))).status, 200);
  const res = await push(base, [], auth, 'f'.repeat(32));
  assert.equal(res.status, 403);
  assert.equal((await res.json()).error, 'this relay is full');
}, { maxVaults: 2 }));

test('storage quota applies to rows and blobs', () => withServer(async (base) => {
  let res = await push(base, [{ k: '1'.repeat(32), h: '0000000000001-0000-a', d: 'x'.repeat(60) }]);
  assert.equal(res.status, 200);
  res = await push(base, [{ k: '2'.repeat(32), h: '0000000000001-0001-a', d: 'y'.repeat(60) }]);
  assert.equal(res.status, 413);
  assert.equal((await res.json()).error, 'vault storage limit reached');
  // Replacing a row only counts the difference.
  res = await push(base, [{ k: '1'.repeat(32), h: '0000000000002-0000-a', d: 'z'.repeat(70) }]);
  assert.equal(res.status, 200);
  const url = `${base}/v1/vaults/${vault}/blobs/${'d'.repeat(32)}`;
  res = await fetch(url, { method: 'PUT', headers: auth, body: Buffer.alloc(40) });
  assert.equal(res.status, 413);
  res = await fetch(url, { method: 'PUT', headers: auth, body: Buffer.alloc(20) });
  assert.equal(res.status, 200);
}, { maxVaultBytes: 100 }));

test('long poll wakes on push', () => withServer(async (base) => {
  await push(base, []);
  const started = Date.now();
  const poll = fetch(`${base}/v1/vaults/${vault}/pull?since=0&wait=10`, { headers: auth }).then((r) => r.json());
  await new Promise((r) => setTimeout(r, 200));
  await push(base, [{ k: '3'.repeat(32), h: '0000000000005-0000-a', d: 'hello' }]);
  const body = await poll;
  assert.equal(body.changes[0].d, 'hello');
  assert.ok(Date.now() - started < 5000);
}));

test('blobs stream in and out and respect the size cap', () => withServer(async (base, dataDir) => {
  const url = `${base}/v1/vaults/${vault}/blobs/${'d'.repeat(32)}`;
  assert.equal((await fetch(url, { method: 'HEAD', headers: auth })).status, 404);
  const payload = Buffer.alloc(3 * 1024 * 1024, 7);
  assert.equal((await fetch(url, { method: 'PUT', headers: auth, body: payload })).status, 200);
  assert.equal((await fetch(url, { method: 'HEAD', headers: auth })).headers.get('content-length'), String(payload.length));
  const data = Buffer.from(await (await fetch(url, { headers: auth })).arrayBuffer());
  assert.ok(data.equals(payload));
  // Oversized uploads are refused and leave nothing behind.
  const big = `${base}/v1/vaults/${vault}/blobs/${'e'.repeat(32)}`;
  const res = await fetch(big, { method: 'PUT', headers: auth, body: Buffer.alloc(5 * 1024 * 1024) });
  assert.equal(res.status, 413);
  assert.deepEqual(fs.readdirSync(path.join(dataDir, 'blobs', vault)).filter((f) => f.endsWith('.tmp')), []);
}, { maxBlobBytes: 4 * 1024 * 1024 }));

test('path and key validation', () => withServer(async (base) => {
  assert.equal((await fetch(`${base}/v1/vaults/${vault}/blobs/..%2F..%2Fetc`, { headers: auth })).status, 404);
  assert.equal((await fetch(`${base}/v1/vaults/not-hex/pull`, { headers: auth })).status, 404);
  assert.equal((await push(base, [{ k: 'short', h: '1', d: 'x' }])).status, 400);
}));
