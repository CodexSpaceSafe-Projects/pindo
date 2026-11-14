import { bindings, defineConfig } from "cf/config";
import staging from "./deployments/staging.json" with { type: "json" };

// Staging has its own remote database and stable identity. Production stays
// blocked until the client and checkpoint/recovery milestones are complete.
export default defineConfig(({ mode }) => {
  if (mode !== "development" && mode !== "staging") throw new Error("The v3 log core is unreleased. Use development or staging mode.");
  const remote = mode === "staging";
  return {
    ...(remote ? { accountId: staging.accountId } : {}),
    worker: {
      name: remote ? staging.workerName : "pindo-sync-v3-development",
      entrypoint: "./src/index.ts",
      compatibilityDate: staging.compatibilityDate,
      env: {
        DB: bindings.d1(remote ? { id: staging.databaseId, name: staging.databaseName } : { name: "pindo-sync-v3-development" }),
        SERVICE_ID: bindings.text(remote ? staging.serviceID : "00000000-0000-4000-8000-000000000001"),
        LOG_CORE_ENABLED: bindings.text("development-only")
      },
      observability: {
        enabled: staging.observability.enabled, redactQueryString: staging.observability.redact_query_string,
        logs: { enabled: staging.observability.logs.enabled, headSamplingRate: staging.observability.logs.head_sampling_rate,
          invocationLogs: staging.observability.logs.invocation_logs },
        traces: { enabled: staging.observability.traces.enabled, headSamplingRate: staging.observability.traces.head_sampling_rate }
      }
    }
  };
});
