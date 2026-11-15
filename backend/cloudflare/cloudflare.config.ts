import { bindings, defineConfig } from "cf/config";
import { loadStagingDeployment } from "./deployments/config.mjs";

// Explicit deployment identity; never create or switch databases implicitly.
export default defineConfig(({ mode }) => {
  if (mode !== "development" && mode !== "staging") throw new Error("Choose development or the configured staging deployment.");
  const remote = mode === "staging";
  const staging = remote ? loadStagingDeployment() : undefined;
  return {
    ...(staging ? { accountId: staging.accountId } : {}),
    worker: {
      name: staging?.workerName ?? "pindo-sync-v3-development",
      entrypoint: "./src/index.ts",
      compatibilityDate: staging?.compatibilityDate ?? "2026-11-14",
      env: {
        DB: bindings.d1(staging ? { id: staging.databaseId, name: staging.databaseName } : { name: "pindo-sync-v3-development" }),
        SERVICE_ID: bindings.text(staging?.serviceID ?? "00000000-0000-4000-8000-000000000001"),
        SYNC_ENABLED: bindings.text("true"),
        BOOTSTRAP_SECRET: bindings.secret(),
        RECOVERY_SECRET: bindings.secret()
      },
      observability: {
        enabled: staging?.observability.enabled ?? true, redactQueryString: true,
        logs: { enabled: staging?.observability.logs.enabled ?? true, headSamplingRate: staging?.observability.logs.head_sampling_rate ?? 0.1,
          invocationLogs: staging?.observability.logs.invocation_logs ?? true },
        traces: { enabled: staging?.observability.traces.enabled ?? true, headSamplingRate: staging?.observability.traces.head_sampling_rate ?? 0.1 }
      }
    }
  };
});
