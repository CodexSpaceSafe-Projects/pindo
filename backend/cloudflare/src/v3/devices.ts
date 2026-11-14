import { boundedJSON, ProtocolError, uuid, sha256 } from '../protocol';
import { Auth, authorize, check, metadata, now, response, stateQuery, tokenHash, VaultState } from './common';
const text=new TextEncoder();
export async function secret(request:Request,expected:string|undefined){
 if(!expected)throw new ProtocolError('maintenance',503);
 const actual=request.headers.get('Authorization')?.replace(/^Bearer /,'')??'';
 const key=await crypto.subtle.importKey('raw',text.encode(expected),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
 const signature=await crypto.subtle.sign('HMAC',key,text.encode(expected));
 if(!await crypto.subtle.verify('HMAC',key,signature,text.encode(actual)))throw new ProtocolError('authentication_required',401);
}
export async function bootstrap(request:Request,env:Env){
 await secret(request,env.BOOTSTRAP_SECRET);
 const b=await boundedJSON(request);if(b.version!==3)throw new ProtocolError('unsupported_version',426);
 const vault=uuid(b.vaultID),epoch=uuid(b.epoch),device=uuid(b.deviceID),hash=await tokenHash(b.deviceToken);
 if(env.SYNC_ENABLED==='true'&&(!b.keyCheck||typeof b.keyCheck!=='object'))throw new ProtocolError('invalid_request',400);
 const keyCheck=b.keyCheck?JSON.stringify(b.keyCheck):null;
 if(keyCheck&&keyCheck.length>4096)throw new ProtocolError('invalid_request',400);
 const r=await env.DB.batch([
 env.DB.prepare(`INSERT INTO vaults(id,epoch,byte_budget,batch_budget,key_check) SELECT ?,?,67108864,1000,? WHERE (SELECT bootstrapped FROM service_state WHERE id=1)=0 AND NOT EXISTS(SELECT 1 FROM vaults WHERE id=?)`).bind(vault,epoch,keyCheck,vault),
 env.DB.prepare(`INSERT INTO devices(id,vault_id,token_hash) SELECT ?,v.id,? FROM vaults v WHERE v.id=? AND v.epoch=? AND (SELECT bootstrapped FROM service_state WHERE id=1)=0 AND NOT EXISTS(SELECT 1 FROM devices WHERE id=?)`).bind(device,hash,vault,epoch,device),
 env.DB.prepare(`UPDATE service_state SET bootstrapped=1 WHERE id=1 AND EXISTS(SELECT 1 FROM devices WHERE id=? AND vault_id=? AND token_hash=?)`).bind(device,vault,hash),stateQuery(env.DB,{vaultID:vault,tokenHash:hash})]);
 const v=r[3].results[0] as VaultState|undefined;if(!v?.device_id)throw new ProtocolError('bootstrap_closed',409);return response(metadata(env,check(v,epoch)));
}
export async function pair(request:Request,env:Env,a:Auth){
 const b=await boundedJSON(request),epoch=uuid(b.epoch),id=uuid(b.id);const code=await tokenHash(b.code);const v=await authorize(env.DB,a,epoch);
 const expiry=now()+10*60*1000;
 const r=await env.DB.batch([
 env.DB.prepare(`INSERT INTO pairing(id,vault_id,epoch,code_hash,created_by,expires_at) SELECT ?,v.id,v.epoch,?,d.id,? FROM vaults v JOIN devices d ON d.vault_id=v.id AND d.token_hash=? AND d.revoked_at IS NULL WHERE v.id=? AND v.epoch=? AND v.maintenance=0 AND NOT EXISTS(SELECT 1 FROM pairing WHERE id=?) AND (SELECT COUNT(*) FROM pairing p WHERE p.vault_id=v.id AND p.expires_at>? AND p.consumed_device IS NULL)<8`).bind(id,code,expiry,a.tokenHash,a.vaultID,epoch,id,now()),
 stateQuery(env.DB,a),env.DB.prepare(`SELECT id,code_hash,expires_at FROM pairing WHERE id=? AND vault_id=? AND epoch=?`).bind(id,a.vaultID,epoch)]);
 check(r[1].results[0] as VaultState|undefined,epoch);const p=r[2].results[0] as {id:string;code_hash:string;expires_at:number}|undefined;
 if(!p)throw new ProtocolError('quota_unavailable',503);if(p.code_hash!==code)throw new ProtocolError('batch_conflict',409);
 return response({...metadata(env,v),pairingID:id,expiresAt:p.expires_at});
}
export async function consume(request:Request,env:Env,vault:string,id:string){
 const b=await boundedJSON(request),epoch=uuid(b.epoch),device=uuid(b.deviceID),hash=await tokenHash(b.deviceToken),code=await tokenHash(b.code),time=now();
 const r=await env.DB.batch([
 env.DB.prepare(`UPDATE pairing SET attempts=attempts+1 WHERE id=? AND vault_id=? AND epoch=? AND consumed_device IS NULL AND expires_at>? AND attempts<8`).bind(id,vault,epoch,time),
 env.DB.prepare(`INSERT INTO devices(id,vault_id,token_hash) SELECT ?,p.vault_id,? FROM pairing p JOIN vaults v ON v.id=p.vault_id AND v.epoch=p.epoch JOIN devices owner ON owner.id=p.created_by AND owner.revoked_at IS NULL WHERE p.id=? AND p.vault_id=? AND p.epoch=? AND p.code_hash=? AND p.consumed_device IS NULL AND p.expires_at>? AND p.attempts<=8 AND changes()>0 AND v.maintenance=0 AND NOT EXISTS(SELECT 1 FROM devices WHERE id=? OR token_hash=?) AND (SELECT COUNT(*) FROM devices WHERE vault_id=v.id AND revoked_at IS NULL)<64`).bind(device,hash,id,vault,epoch,code,time,device,hash),
 env.DB.prepare(`UPDATE pairing SET consumed_device=?,consumed_hash=? WHERE id=? AND vault_id=? AND code_hash=? AND EXISTS(SELECT 1 FROM devices WHERE id=? AND vault_id=? AND token_hash=?)`).bind(device,hash,id,vault,code,device,vault,hash),
 stateQuery(env.DB,{vaultID:vault,tokenHash:hash})]);
 const v=r[3].results[0] as VaultState|undefined;if(!v?.device_id)throw new ProtocolError('pairing_invalid',401);return response(metadata(env,check(v,epoch)));
}
export async function devices(request:Request,env:Env,a:Auth,path:string){
 if(request.method==='GET'&&path==='devices'){const r=await env.DB.batch([stateQuery(env.DB,a),env.DB.prepare('SELECT id,revoked_at FROM devices WHERE vault_id=? ORDER BY id').bind(a.vaultID)]);const v=check(r[0].results[0] as VaultState|undefined);return response({...metadata(env,v),devices:r[1].results});}
 const b=await boundedJSON(request),epoch=uuid(b.epoch);const parts=path.split('/');const id=uuid(parts[1]);
 if(parts[2]==='revoke'){
 const r=await env.DB.batch([env.DB.prepare(`UPDATE devices SET revoked_at=COALESCE(revoked_at,?) WHERE id=? AND vault_id=? AND EXISTS(SELECT 1 FROM devices a JOIN vaults v ON a.vault_id=v.id WHERE a.token_hash=? AND a.revoked_at IS NULL AND v.id=? AND v.epoch=? AND v.maintenance=0)`).bind(now(),id,a.vaultID,a.tokenHash,a.vaultID,epoch),stateQuery(env.DB,a)]);
 if(!r[0].meta.changes)check(r[1].results[0] as VaultState|undefined,epoch);return response({revoked:true,deviceID:id});}
 if(parts[2]==='rotate'){
 const hash=await tokenHash(b.deviceToken);
 await env.DB.prepare(`UPDATE devices SET token_hash=? WHERE id=? AND vault_id=? AND token_hash=? AND revoked_at IS NULL AND EXISTS(SELECT 1 FROM vaults WHERE id=? AND epoch=? AND maintenance=0)`).bind(hash,id,a.vaultID,a.tokenHash,a.vaultID,epoch).run();
 const v=await authorize(env.DB,{vaultID:a.vaultID,tokenHash:hash},epoch);return response(metadata(env,v));}
 throw new ProtocolError('not_found',404);
}
