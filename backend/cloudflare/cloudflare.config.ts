import { bindings, defineConfig } from "cf/config";
import staging from "./deployments/staging.json" with { type: "json" };

// Explicit deployment identity; never create or switch databases implicitly.
export default defineConfig(({ mode }) => {
  if (mode !== "development" && mode !== "staging") throw new Error("Choose development or the configured staging deployment.");
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
        SYNC_ENABLED: bindings.text("true"),
        BOOTSTRAP_SECRET: bindings.secret(),
        RECOVERY_SECRET: bindings.secret()
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
