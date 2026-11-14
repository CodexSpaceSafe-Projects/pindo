import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const directory = fileURLToPath(new URL('../', import.meta.url));
const root = fileURLToPath(new URL('../../../', import.meta.url));
const output = new URL('../../../work/cloudflare-staging/', import.meta.url);
const deployment = JSON.parse(await readFile(new URL('../deployments/staging.json', import.meta.url), 'utf8'));
const dirty = execFileSync('git', ['status', '--porcelain', '--', 'backend/cloudflare'], {cwd:root,encoding:'utf8'}).trim();
if (dirty) throw new Error('Commit backend changes before building a versioned deployment.');
const sourceRevision = execFileSync('git', ['rev-parse', 'HEAD'], {cwd:root,encoding:'utf8'}).trim();
const result = await build({
  stdin: {contents:'export { default } from "./src/index.ts";',resolveDir:directory,sourcefile:'deployment-entry.ts'},
  bundle:true,format:'esm',platform:'neutral',target:'es2022',write:false
});
const source = result.outputFiles[0].text;
const bundleSHA256 = createHash('sha256').update(source).digest('hex');
const metadata = {
  main_module:'worker.mjs',compatibility_date:deployment.compatibilityDate,
  bindings:[
    {type:'d1',name:'DB',database_id:deployment.databaseId},
    {type:'plain_text',name:'SERVICE_ID',text:deployment.serviceID},
    {type:'plain_text',name:'LOG_CORE_ENABLED',text:'development-only'}
  ],
  observability:deployment.observability,
  tags:['pindo','sync-v3','staging'],
  annotations:{'workers/message':`Pindo staging ${sourceRevision}; SHA256 ${bundleSHA256}`,'workers/tag':sourceRevision.slice(0,12)}
};
await mkdir(output,{recursive:true});
await writeFile(new URL('worker.mjs',output),source);
await writeFile(new URL('metadata.json',output),JSON.stringify(metadata,null,2)+'\n');
await writeFile(new URL('build.json',output),JSON.stringify({sourceRevision,bundleSHA256,endpoint:deployment.endpoint},null,2)+'\n');
console.log(JSON.stringify({sourceRevision,bundleSHA256,output:fileURLToPath(output)}));
