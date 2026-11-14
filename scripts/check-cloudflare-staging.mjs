import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Public deployment probes only. No account credentials or device tokens.
const deployment = JSON.parse(await readFile(new URL('../backend/cloudflare/deployments/staging.json', import.meta.url), 'utf8'));
const endpoint = new URL(deployment.endpoint);
assert.equal(endpoint.protocol, 'https:');
assert.equal(endpoint.hostname, 'pindo-sync-v3-staging.zhchain.workers.dev');
const get = async (path) => {
  const response = await fetch(new URL(path, endpoint), {redirect:'error',signal:AbortSignal.timeout(15000)});
  return {status:response.status,cache:response.headers.get('Cache-Control'),body:await response.json()};
};
let health;
for (let attempt=0; attempt<6; attempt++) {
  try {
    health=await get('/health');
    assert.equal(health.status,200);
    break;
  } catch (error) {
    if (attempt===5) throw error;
    await new Promise(resolve=>setTimeout(resolve,5000));
  }
}
assert.equal(health.cache,'no-store');
assert.equal(health.body.service,'pindo-sync');
assert.equal(health.body.serviceID,deployment.serviceID);
assert.equal(health.body.version,3);
assert.equal(health.body.status,'ok');
assert.equal(health.body.clientSyncAvailable,false);
const root=await get('/');
assert.equal(root.status,200);
assert.equal(root.body.serviceID,deployment.serviceID);
const unauthorized=await get('/v3/vaults/00000000-0000-4000-8000-000000000002/info');
assert.equal(unauthorized.status,401);
assert.equal(unauthorized.body.error.code,'authentication_required');
console.log(JSON.stringify({endpoint:deployment.endpoint,health:health.status,root:root.status,
  unauthorized:unauthorized.status,serviceID:deployment.serviceID,clientSyncAvailable:false}));
