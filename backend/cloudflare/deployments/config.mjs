import { readFileSync } from 'node:fs';

export function loadStagingDeployment() {
  let deployment;
  try {
    deployment = JSON.parse(readFileSync(new URL('./staging.local.json', import.meta.url), 'utf8'));
  } catch {
    throw new Error('Create deployments/staging.local.json from staging.example.json and fill in your private deployment settings.');
  }
  let endpoint;
  try { endpoint = new URL(deployment?.endpoint); } catch {}
  const required = ['accountId', 'workerName', 'endpoint', 'databaseName', 'databaseId', 'serviceID', 'compatibilityDate'];
  if (required.some(key => typeof deployment?.[key] !== 'string' || !deployment[key]) ||
      !endpoint || endpoint.protocol !== 'https:' || endpoint.username || endpoint.password ||
      !/^[a-f0-9]{32}$/i.test(deployment.accountId) ||
      [deployment.databaseId, deployment.serviceID].some(value => !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value)) ||
      !deployment.observability) {
    throw new Error('Private deployment settings are incomplete; replace every placeholder in deployments/staging.local.json.');
  }
  return deployment;
}
