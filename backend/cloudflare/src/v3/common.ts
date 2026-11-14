import { ProtocolError, uuid, sha256 } from '../protocol';
export type VaultState = {id:string;epoch:string;head:number;gc_floor:number;maintenance:number;charged_bytes:number;byte_budget:number;batch_budget:number;log_count:number;log_bytes:number;checkpoint_id:string|null;device_id:string|null};
export type Auth = {vaultID:string;tokenHash:string};
export const now = () => Date.now();
export function response(body:unknown,status=200):Response{return Response.json(body,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});}
export function stateQuery(db:D1Database,a:Auth):D1PreparedStatement{return db.prepare(`SELECT v.*,d.id AS device_id FROM vaults v LEFT JOIN devices d ON d.vault_id=v.id AND d.token_hash=? AND d.revoked_at IS NULL WHERE v.id=?`).bind(a.tokenHash,a.vaultID);}
export function check(v:VaultState|undefined,epoch?:string):VaultState{if(!v?.device_id)throw new ProtocolError('authentication_required',401);if(v.maintenance)throw new ProtocolError('maintenance',503);if(epoch!==undefined&&v.epoch!==epoch)throw new ProtocolError('epoch_mismatch',409);return v;}
export function ids(value:unknown):string[]{if(value===undefined)return [];if(!Array.isArray(value)||value.length>512||value.some((x,i)=>typeof x!=='string'||!/^[a-f0-9]{64}$/.test(x)||(i>0&&value[i-1]>=x)))throw new ProtocolError('invalid_request',400);return value as string[];}
export function token(value:unknown):string{if(typeof value!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(value))throw new ProtocolError('authentication_required',401);return value;}
export async function tokenHash(value:unknown):Promise<string>{return sha256(new TextEncoder().encode(token(value)));}
export async function auth(request:Request,vaultID:string):Promise<Auth>{const h=request.headers.get('Authorization');if(!h?.startsWith('Bearer '))throw new ProtocolError('authentication_required',401);return {vaultID:uuid(vaultID),tokenHash:await tokenHash(h.slice(7))};}
export function metadata(env:Env,v:VaultState){return {version:3,serviceID:env.SERVICE_ID,vaultID:v.id,epoch:v.epoch,head:v.head,gcFloor:v.gc_floor,checkpointID:v.checkpoint_id,logCount:v.log_count,logBytes:v.log_bytes};}
export function refsGuard(refs:string[]):{sql:string;params:(string|number)[]}{return {sql:`(SELECT COUNT(*) FROM artifacts a WHERE a.vault_id=v.id AND a.epoch=v.epoch AND a.digest IN (SELECT value FROM json_each(?)))=?`,params:[JSON.stringify(refs),refs.length]};}
export async function authorize(db:D1Database,a:Auth,epoch?:string){const r=await db.batch([stateQuery(db,a)]);return check(r[0].results[0] as VaultState|undefined,epoch);}
export function usage(r:D1Result<unknown>[],route:string){console.log(JSON.stringify({event:'d1_usage',route,rows_read:r.reduce((s,x)=>s+x.meta.rows_read,0),rows_written:r.reduce((s,x)=>s+x.meta.rows_written,0)}));}
