import { after, before, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile,readdir } from 'node:fs/promises';
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
    bindings: { SERVICE_ID: serviceID, LOG_CORE_ENABLED: 'development-only',BOOTSTRAP_SECRET:'test-bootstrap-secret',RECOVERY_SECRET:'test-recovery-secret' }, log: new Log(LogLevel.ERROR) });
  db = await mf.getD1Database('DB');
  for(const file of (await readdir(new URL('../migrations/',import.meta.url))).filter(x=>x.endsWith('.sql')).sort()) {
    const schema=await readFile(new URL('../migrations/'+file,import.meta.url),'utf8');
    await db.exec(schema.replace(/--[^\n]*/g,'').replace(/\n/g,' '));
  }
});
after(async () => { await mf?.dispose(); });
beforeEach(async () => {
  await db.batch([
    db.prepare('DROP TRIGGER IF EXISTS fail_receipt'), db.prepare('DROP TRIGGER IF EXISTS fail_counter'),
    ...['commit_artifacts','checkpoint_artifacts','artifacts','checkpoints','leases','pairing','mutations'].map(t=>db.prepare('DELETE FROM '+t)),
    db.prepare('UPDATE service_state SET bootstrapped=0'),
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
  assert.equal((await request('push',{...body(),artifactIDs:['a'.repeat(64)]})).body.error.code,'artifact_missing');
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

test('bootstrap closes after one vault and pairing consumes once atomically with retry proof', async () => {
  await db.batch([db.prepare('DELETE FROM devices'),db.prepare('DELETE FROM vaults')]);
  const created={version:3,vaultID,epoch,deviceID,deviceToken:token};
  const init=await mf.dispatchFetch('https://sync.test/v3/bootstrap',{method:'POST',headers:{Authorization:'Bearer test-bootstrap-secret','Content-Type':'application/json'},body:JSON.stringify(created)});
  assert.equal(init.status,200);assert.equal((await init.json()).vaultID,vaultID);
  const second=await mf.dispatchFetch('https://sync.test/v3/bootstrap',{method:'POST',headers:{Authorization:'Bearer test-bootstrap-secret','Content-Type':'application/json'},body:JSON.stringify({...created,vaultID:id(90),deviceID:id(91)})});
  assert.equal(second.status,409);
  const pairID=id(80),code=Buffer.alloc(32,9).toString('base64url');
  assert.equal((await request('pairings',{epoch,id:pairID,code})).status,200);
  const newToken=Buffer.alloc(32,10).toString('base64url'),newDevice=id(81);
  const consume={epoch,code,deviceID:newDevice,deviceToken:newToken};
  const a=await request(`pairings/${pairID}/consume`,consume);assert.equal(a.status,200);
  assert.deepEqual(await request(`pairings/${pairID}/consume`,consume),a);
  assert.equal((await request('info',undefined,newToken)).status,200);
  assert.equal((await request(`pairings/${pairID}/consume`,{...consume,deviceID:id(82),deviceToken:Buffer.alloc(32,11).toString('base64url')})).status,401);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM devices').first()).n,2);
});

test('pair attempt cap, expired codes, token rotation and self revocation', async () => {
  const pairID=id(80),code=Buffer.alloc(32,9).toString('base64url');
  await request('pairings',{epoch,id:pairID,code});
  const consume={epoch,code:Buffer.alloc(32,8).toString('base64url'),deviceID:id(81),deviceToken:Buffer.alloc(32,10).toString('base64url')};
  for(let i=0;i<8;i++)assert.equal((await request(`pairings/${pairID}/consume`,consume)).status,401);
  assert.equal((await request(`pairings/${pairID}/consume`,{...consume,code})).status,401);
  const rotated=Buffer.alloc(32,12).toString('base64url');
  assert.equal((await request(`devices/${deviceID}/rotate`,{epoch,deviceToken:rotated})).status,200);
  assert.equal((await request('info')).status,401);
  assert.equal((await request('info',undefined,rotated)).status,200);
  assert.equal((await request(`devices/${deviceID}/revoke`,{epoch},rotated)).status,200);
  assert.equal((await request('info',undefined,rotated)).status,401);
});

test('immutable chunk integrity, checkpoint CAS, two recovery entries and safe GC', async () => {
  const chunk=Buffer.alloc(64,6),digest=createHash('sha256').update(chunk).digest('hex'),objectID=id(70);
  const upload={epoch,objectID,ciphertext:chunk.toString('base64')};
  assert.equal((await request(`artifacts/${digest}`,upload)).status,200);
  assert.equal((await request(`artifacts/${digest}`,upload)).status,200);
  assert.equal((await request(`artifacts/${digest}?epoch=${epoch}`)).body.ciphertext,upload.ciphertext);
  const first=await request('push',{...body(),artifactIDs:[digest]});assert.equal(first.status,200);
  const cp=(n,covered,expectedID)=>({epoch,id:id(100+n),covered,expectedID,ciphertext:Buffer.alloc(64,n+1).toString('base64'),artifactIDs:[digest]});
  const c1=await request('checkpoints',cp(0,1,null));assert.equal(c1.status,200);
  assert.equal((await request('checkpoints',cp(0,1,null))).status,200);
  await request('push',body(1));
  assert.equal((await request('checkpoints',cp(1,2,null))).body.error.code,'checkpoint_conflict');
  assert.equal((await request('checkpoints',cp(1,2,id(100)))).status,200);
  await request('push',body(2));
  assert.equal((await request('checkpoints',cp(2,3,id(101)))).status,200);
  const gc=await request('gc',{epoch});assert.equal(gc.status,200);assert.equal(gc.body.gcFloor,2);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM checkpoints').first()).n,2);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM commits').first()).n,1);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM receipts').first()).n,3);
  assert.equal((await request('push',body(3))).body.receipt.revision,4);
  assert.equal((await request(`pull?epoch=${epoch}&after=0`)).body.error.code,'checkpoint_required');
  assert.equal((await request(`artifacts/${digest}?epoch=${epoch}`)).status,200);
});

test('read lease keeps old checkpoint tail; chunk GC respects every retained reference', async () => {
  await request('push',body());await request('push',body(1));await request('push',body(2));
  const leaseID=id(60);assert.equal((await request(`leases/${leaseID}`,{epoch,floor:0})).status,200);
  const cp=(n,covered,expectedID)=>({epoch,id:id(100+n),covered,expectedID,ciphertext:Buffer.alloc(64,n+1).toString('base64')});
  assert.equal((await request('checkpoints',cp(0,1,null))).status,200);
  assert.equal((await request('checkpoints',cp(1,2,id(100)))).status,200);
  assert.equal((await request('gc',{epoch})).body.gcFloor,0);
  await db.prepare('UPDATE leases SET expires_at=0').run();
  assert.equal((await request('gc',{epoch})).body.gcFloor,1);
  const chunk=Buffer.alloc(64,6),digest=createHash('sha256').update(chunk).digest('hex');
  await request(`artifacts/${digest}`,{epoch,objectID:id(70),ciphertext:chunk.toString('base64')});
  await db.prepare('UPDATE artifacts SET lease_until=0').run();
  assert.equal((await request('gc',{epoch})).status,200);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM artifacts').first()).n,0);
});

test('recovery requires maintenance, preserves old prefix under a lease and gates new uploads',async()=>{
 await request('push',body());await request('push',body(1));
 const admin=async(path,data)=>{const r=await mf.dispatchFetch('https://sync.test/v3/admin/'+path,{method:'POST',headers:{Authorization:'Bearer test-recovery-secret','Content-Type':'application/json'},body:JSON.stringify(data)});return{status:r.status,body:await r.json()};};
 const next=id(220);
 assert.equal((await admin('recover',{vaultID,epoch:next})).status,409);
 assert.equal((await admin('maintenance',{vaultID,enabled:true})).status,200);
 assert.equal((await request('push',body(2))).body.error.code,'maintenance');
 assert.equal((await admin('recover',{vaultID,epoch:next})).status,200);
 const info=await request('info');assert.equal(info.body.epoch,next);assert.equal(info.body.recoveryHead,2);assert.equal(info.body.head,0);
 assert.equal((await request('push',{...body(2),epoch:next})).body.error.code,'checkpoint_required');
 const cp=await request(`checkpoints?epoch=${epoch}`);assert.equal(cp.status,200);
 const old=await request(`pull?epoch=${epoch}&after=0&lease=${cp.body.leaseID}`);assert.equal(old.body.commits.length,2);
 const publish=await request('checkpoints',{epoch:next,id:id(221),covered:0,expectedID:null,ciphertext:body(9).ciphertext,artifactIDs:[]});assert.equal(publish.status,200);
 assert.equal((await request('push',{...body(2),epoch:next})).status,200);
 await request('gc',{epoch:next});assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM commits WHERE epoch=?').bind(epoch).first()).n,2);
 assert.equal((await request(`receipts/${id(0)}?epoch=${epoch}`)).body.error.code,'epoch_mismatch');
 await db.prepare('UPDATE leases SET expires_at=0').run();await request('gc',{epoch:next});
 assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM commits WHERE epoch=?').bind(epoch).first()).n,0);
 assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM receipts WHERE epoch=?').bind(epoch).first()).n,2);
});

test('checkpoint retry neither charges twice nor moves the pointer backwards; missing artifacts publish nothing',async()=>{
 await request('push',body());const checkpoint={epoch,id:id(230),covered:1,expectedID:null,ciphertext:body(7).ciphertext,artifactIDs:[]};
 const first=await request('checkpoints',checkpoint);assert.equal(first.status,200);
 const charge=(await db.prepare('SELECT charged_bytes FROM vaults').first()).charged_bytes;
 assert.deepEqual(await request('checkpoints',checkpoint),first);
 assert.equal((await db.prepare('SELECT charged_bytes FROM vaults').first()).charged_bytes,charge);
 const forged=await request('checkpoints',{...checkpoint,expectedID:checkpoint.id});assert.equal(forged.status,200);
 assert.equal((await db.prepare('SELECT charged_bytes FROM vaults').first()).charged_bytes,charge);
 await request('push',body(1));
 const absent=await request('checkpoints',{...checkpoint,id:id(231),covered:2,expectedID:checkpoint.id,artifactIDs:['a'.repeat(64)]});assert.equal(absent.body.error.code,'artifact_missing');
 assert.equal((await db.prepare('SELECT checkpoint_id FROM vaults').first()).checkpoint_id,checkpoint.id);
});

test('revoked devices cannot publish checkpoints, allocate chunks or advance GC after earlier authorization',async()=>{
 await request('push',body());assert.equal((await request('info')).status,200);await db.prepare('UPDATE devices SET revoked_at=1').run();
 for(const [path,value] of[['checkpoints',{epoch,id:id(240),covered:1,expectedID:null,ciphertext:body().ciphertext,artifactIDs:[]}],['gc',{epoch}]])assert.equal((await request(path,value)).status,401);
 assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM checkpoints').first()).n,0);assert.equal((await db.prepare('SELECT gc_floor FROM vaults').first()).gc_floor,0);
});
