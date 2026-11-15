// Loopback-only real Worker/D1 server for native client interoperability tests.
import {createTestWorker} from './runtime.mjs';
import {createServer} from 'node:http';
const serviceID='00000000-0000-4000-8000-000000000001';
const {mf}=await createTestWorker({SERVICE_ID:serviceID,SYNC_ENABLED:'true',BOOTSTRAP_SECRET:'integration-bootstrap',RECOVERY_SECRET:'integration-recovery'});
const server=createServer(async(req,res)=>{try{const parts=[];for await(const p of req)parts.push(p);const response=await mf.dispatchFetch('https://sync.test'+req.url,{method:req.method,headers:req.headers,...(parts.length?{body:Buffer.concat(parts)}:{})});res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));}catch(e){console.error(e);res.writeHead(500);res.end('{}');}});
server.listen(Number(process.env.PINDO_TEST_PORT??8787),'127.0.0.1',()=>console.log('PINDO_INTEGRATION_READY'));
for(const signal of['SIGTERM','SIGINT'])process.on(signal,async()=>{server.close();await mf.dispose();process.exit(0);});
