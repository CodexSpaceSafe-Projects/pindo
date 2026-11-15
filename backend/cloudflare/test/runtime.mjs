import { readFile, readdir } from 'node:fs/promises';
import { Miniflare, Log, LogLevel } from 'miniflare';

export async function createTestWorker(bindings) {
  const mf = new Miniflare({
    modules: true,
    modulesRoot: new URL('../../../work/', import.meta.url).pathname,
    scriptPath: new URL('../../../work/cloudflare-worker.mjs', import.meta.url).pathname,
    // Pinned local runtime and deployed compatibility dates are independent.
    compatibilityDate: '2026-07-30',
    d1Databases: ['DB'], bindings, log: new Log(LogLevel.ERROR)
  });
  try {
    const db = await mf.getD1Database('DB');
    const migrations = new URL('../migrations/', import.meta.url);
    for (const name of (await readdir(migrations)).filter(name => name.endsWith('.sql')).sort()) {
      const schema = await readFile(new URL(name, migrations), 'utf8');
      await db.exec(schema.replace(/--[^\n]*/g, '').replace(/\n/g, ' '));
    }
    return { mf, db };
  } catch (error) {
    await mf.dispose();
    throw error;
  }
}
