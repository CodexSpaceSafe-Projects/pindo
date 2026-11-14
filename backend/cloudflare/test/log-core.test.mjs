import { after, before, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, createCipheriv } from 'node:crypto';
import { Miniflare, Log, LogLevel } from 'miniflare';
import { appendBatch } from '../../../work/cloudflare-worker.mjs';

const serviceID = '00000000-0000-4000-8000-000000000001';
const vaultID = '00000000-0000-4000-8000-000000000002';
const epoch = '00000000-0000-4000-8000-000000000003';
const deviceID = '00000000-0000-4000-8000-000000000004';
const token = Buffer.alloc(32, 7).toString('base64url');
const tokenHash = createHash('sha256').update(token).digest('hex');
const id = n => `00000000-0000-4000-8000-${String(n + 10).padStart(12, '0')}`;
const body = (n = 0) => ({version: 3, epoch, batchID: id(n), ciphertext: Buffer.alloc(48, n).toString('base64')});
let mf, db;
const url = path => `https://sync.test/v3/vaults/${vaultID}/${path}`;
async function request(path, data, auth = token) {
  const response = await mf.dispatchFetch(url(path), {
    method: data ? 'POST' : 'GET', headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' },
    ...(data ? { body: JSON.stringify(data) } : {})
  });
  return { status: response.status, body: await response.json() };
}
before(async () => {
  mf = new Miniflare({ modules: true, modulesRoot: new URL('../../../work/', import.meta.url).pathname, scriptPath: new URL('../../../work/cloudflare-worker.mjs', import.meta.url).pathname,
    // Pinned local runtime supports this date; deployment target is separately versioned.
    compatibilityDate: '2026-07-30', d1Databases: ['DB'],
    bindings: { SERVICE_ID: serviceID, LOG_CORE_ENABLED: 'development-only' }, log: new Log(LogLevel.ERROR) });
  db = await mf.getD1Database('DB');
  const schema = await readFile(new URL('../migrations/0001_log_core.sql', import.meta.url), 'utf8');
  await db.exec(schema.replace(/--[^\n]*/g, '').replace(/\n/g, ' '));
});
after(async () => { await mf?.dispose(); });
beforeEach(async () => {
  await db.batch([
    db.prepare('DROP TRIGGER IF EXISTS fail_receipt'), db.prepare('DROP TRIGGER IF EXISTS fail_counter'),
    db.prepare('DELETE FROM commits'), db.prepare('DELETE FROM receipts'), db.prepare('DELETE FROM devices'), db.prepare('DELETE FROM vaults'),
    db.prepare('INSERT INTO vaults(id,epoch) VALUES(?,?)').bind(vaultID, epoch),
    db.prepare('INSERT INTO devices(id,vault_id,token_hash) VALUES(?,?,?)').bind(deviceID, vaultID, tokenHash)
  ]);
});

test('public health verifies all schema bindings without exposing a device credential', async () => {
  const response = await mf.dispatchFetch('https://sync.test/health');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(await response.json(), {service:'pindo-sync',version:3,status:'ok',serviceID,
    capabilities:['development-log-core'],clientSyncAvailable:false});
  assert.equal((await mf.dispatchFetch('https://sync.test/')).status, 200);
  assert.equal((await mf.dispatchFetch(url('info'))).status, 401);
});

test('health fails closed if a required database table is missing', async () => {
  await db.prepare('ALTER TABLE receipts RENAME TO retained_receipts').run();
  try {
    const response = await mf.dispatchFetch('https://sync.test/health');
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error.code, 'storage_unavailable');
  } finally { await db.prepare('ALTER TABLE retained_receipts RENAME TO receipts').run(); }
});

test('push is idempotent, changed bytes conflict, and receipt is independent of pull cursor', async () => {
  const first = await request('push', body()); assert.equal(first.status, 200);
  assert.equal(first.body.receipt.revision, 1); assert.equal('nextCursor' in first.body, false);
  assert.deepEqual(await request('push', body()), first);
  const conflict = await request('push', {...body(), ciphertext: body(1).ciphertext});
  assert.equal(conflict.status, 409); assert.equal(conflict.body.error.code, 'batch_conflict');
  const receipt = await request(`receipts/${id(0)}?epoch=${epoch}`); assert.deepEqual(receipt, first);
  const pull = await request(`pull?epoch=${epoch}&after=0`);
  assert.equal(pull.body.nextCursor, 1); assert.equal(pull.body.commits.length, 1);
  assert.equal((await db.prepare('SELECT head FROM vaults').first()).head, 1);
});

test('concurrent distinct batches receive a contiguous total order', async () => {
  const replies = await Promise.all(Array.from({length: 16}, (_, i) => request('push', body(i))));
  assert.ok(replies.every(r => r.status === 200));
  assert.deepEqual(replies.map(r => r.body.receipt.revision).sort((a,b) => a-b), Array.from({length:16}, (_,i) => i+1));
  const first = await request(`pull?epoch=${epoch}&after=0`); assert.equal(first.body.commits.length, 8); assert.equal(first.body.hasMore, true);
  const next = await request(`pull?epoch=${epoch}&after=${first.body.nextCursor}`); assert.equal(next.body.nextCursor, 16); assert.equal(next.body.hasMore, false);
});

test('concurrent retries of the same frozen batch share one receipt and one charge', async () => {
  const replies = await Promise.all(Array.from({length: 8}, () => request('push', body())));
  assert.ok(replies.every(r => r.status === 200));
  assert.ok(replies.every(r => JSON.stringify(r.body) === JSON.stringify(replies[0].body)));
  assert.equal((await db.prepare('SELECT head,charged_bytes FROM vaults').first()).charged_bytes, 2112);
});

for (const [trigger, table] of [['fail_receipt','receipts'], ['fail_counter','vaults']]) {
  test(`constraint failure in ${table} rolls the entire D1 batch back`, async () => {
    await db.prepare(`CREATE TRIGGER ${trigger} BEFORE ${table === 'vaults' ? 'UPDATE' : 'INSERT'} ON ${table} BEGIN SELECT RAISE(ABORT,'injected failure'); END`).run();
    const result = await request('push', body()); assert.equal(result.status, 503);
    assert.equal(result.body.error.code, 'storage_unavailable');
    assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM commits').first()).n, 0);
    assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM receipts').first()).n, 0);
    assert.equal((await db.prepare('SELECT head,charged_bytes FROM vaults').first()).head, 0);
    await db.prepare(`DROP TRIGGER ${trigger}`).run();
    assert.equal((await request('push', body())).body.receipt.revision, 1);
  });
}

test('revocation after preflight is enforced inside the append transaction', async () => {
  assert.equal((await request('info')).status, 200); // earlier authorization is no authority to write
  await db.prepare('UPDATE devices SET revoked_at=1').run();
  await assert.rejects(appendBatch(new Request(url('push'), {method:'POST', headers:{'Content-Type':'application/json'},body:JSON.stringify(body())}),
    {DB:db,SERVICE_ID:serviceID}, {vaultID,tokenHash}), e => e.code === 'authentication_required');
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM commits').first()).n, 0);
  assert.equal((await request(`pull?epoch=${epoch}&after=0`)).status, 401);
});

test('epoch changes, maintenance, quota and future cursors fail without writes', async () => {
  const changed = await request('push', {...body(), epoch:id(99)}); assert.equal(changed.body.error.code,'epoch_mismatch');
  await db.prepare('UPDATE vaults SET maintenance=1').run(); assert.equal((await request('push',body())).body.error.code,'maintenance');
  await db.prepare('UPDATE vaults SET maintenance=0,byte_budget=1').run(); assert.equal((await request('push',body())).body.error.code,'quota_unavailable');
  assert.equal((await request(`pull?epoch=${epoch}&after=1`)).body.error.code,'cursor_mismatch');
  assert.equal((await db.prepare('SELECT head FROM vaults').first()).head,0);
});

test('receipt survives simulated GC, head never comes from MAX(revision), and old cursor requires checkpoint', async () => {
  const first = await request('push', body());
  await db.batch([db.prepare('DELETE FROM commits'), db.prepare('UPDATE vaults SET gc_floor=head')]);
  assert.deepEqual(await request('push', body()), first);
  assert.deepEqual(await request(`receipts/${id(0)}?epoch=${epoch}`), first);
  assert.equal((await request('push',body(1))).body.receipt.revision, 2);
  assert.equal((await request(`pull?epoch=${epoch}&after=0`)).body.error.code,'checkpoint_required');
  assert.equal((await request(`pull?epoch=${epoch}&after=1`)).body.commits[0].revision,2);
});

test('malformed, oversized, unknown version and unauthorized requests fail closed', async () => {
  assert.equal((await request('push', body(), 'invalid')).body.error.code,'authentication_required');
  assert.equal((await request('push',{...body(),version:2})).body.error.code,'unsupported_version');
  assert.equal((await request('push',{...body(),ciphertext:'invalid'})).body.error.code,'corrupt_data');
  assert.equal((await request('push',{...body(),artifactIDs:['a'.repeat(64)]})).body.error.code,'unsupported_feature');
  assert.equal((await request('push',{...body(),ciphertext:Buffer.alloc(128*1024+1).toString('base64')})).status,400);
  assert.equal((await request('push',{...body(),padding:'a'.repeat(176*1024)})).status,413);
  for (const after of ['-1','01','1.0','9007199254740992']) assert.equal((await request(`pull?epoch=${epoch}&after=${after}`)).status,400);
});

test('gaps in a retained log are corruption and cannot advance a cursor', async () => {
  await request('push',body()); await request('push',body(1));
  await db.prepare('DELETE FROM commits WHERE revision=1').run();
  assert.equal((await request(`pull?epoch=${epoch}&after=0`)).body.error.code,'corrupt_data');
});

test('shared AAD and encryption vector is bound to service, vault, epoch and batch', async () => {
  const fixture = JSON.parse(await readFile(new URL('../../../sync-vectors/v3-contract.json', import.meta.url), 'utf8'));
  const c=fixture.context;
  const associated=Buffer.from(['PindoSync/v3',c.serviceID,c.vaultID,c.epoch,c.kind,c.objectID,c.artifactIDs.join(',')].join('\n'));
  assert.equal(associated.toString('hex'),fixture.aadHex);
  const cipher=createCipheriv('aes-256-gcm',Buffer.from(fixture.keyHex,'hex'),Buffer.from(fixture.nonceHex,'hex'));
  cipher.setAAD(associated); const encrypted=Buffer.concat([cipher.update(fixture.plaintext,'utf8'),cipher.final()]);
  const sealed=Buffer.concat([Buffer.from(fixture.nonceHex,'hex'),encrypted,cipher.getAuthTag()]);
  assert.equal(sealed.toString('base64'),fixture.ciphertext);
  const result=await request('push',{version:3,epoch:c.epoch,batchID:c.objectID,ciphertext:fixture.ciphertext});
  assert.equal(result.body.receipt.digest,fixture.digest);
});
