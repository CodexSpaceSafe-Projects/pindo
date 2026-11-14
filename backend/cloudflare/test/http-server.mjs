// Loopback-only real Worker/D1 server for native client interoperability tests.
import {Miniflare,Log,LogLevel} from 'miniflare';
import {readFile,readdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createHash,createCipheriv} from 'node:crypto';
const serviceID='00000000-0000-4000-8000-000000000001';
const mf=new Miniflare({modules:true,modulesRoot:new URL('../../../work/',import.meta.url).pathname,
 scriptPath:new URL('../../../work/cloudflare-worker.mjs',import.meta.url).pathname,compatibilityDate:'2026-07-30',d1Databases:['DB'],
 bindings:{SERVICE_ID:serviceID,SYNC_ENABLED:'true',BOOTSTRAP_SECRET:'integration-bootstrap',RECOVERY_SECRET:'integration-recovery'},log:new Log(LogLevel.ERROR)});
const db=await mf.getD1Database('DB');
for(const f of(await readdir(new URL('../migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort())await db.exec((await readFile(new URL('../migrations/'+f,import.meta.url),'utf8')).replace(/--[^\n]*/g,'').replace(/\n/g,' '));
const server=createServer(async(req,res)=>{try{const parts=[];for await(const p of req)parts.push(p);const response=await mf.dispatchFetch('https://sync.test'+req.url,{method:req.method,headers:req.headers,...(parts.length?{body:Buffer.concat(parts)}:{})});res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));}catch(e){console.error(e);res.writeHead(500);res.end('{}');}});
server.listen(Number(process.env.PINDO_TEST_PORT??8787),'127.0.0.1',()=>console.log('PINDO_INTEGRATION_READY'));
for(const signal of['SIGTERM','SIGINT'])process.on(signal,async()=>{server.close();await mf.dispose();process.exit(0);});
