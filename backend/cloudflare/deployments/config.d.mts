export interface Deployment {
  accountId: string;
  workerName: string;
  endpoint: string;
  databaseName: string;
  databaseId: string;
  serviceID: string;
  compatibilityDate: string;
  observability: {
    enabled: boolean;
    redact_query_string: boolean;
    logs: { enabled: boolean; invocation_logs: boolean; head_sampling_rate: number };
    traces: { enabled: boolean; head_sampling_rate: number };
  };
}
export function loadStagingDeployment(): Deployment;
