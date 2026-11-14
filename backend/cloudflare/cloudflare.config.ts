import { bindings, defineConfig } from "cf/config";

// No production mode until P2/P4/P5 are complete. Local resources and identities
// must not be reused for a production service.
export default defineConfig(({ mode }) => {
  if (mode !== "development") throw new Error("The v3 log core is unreleased. Use development mode with an isolated test database.");
  return {
    worker: {
      name: "pindo-sync-v3-development",
      entrypoint: "./src/index.ts",
      compatibilityDate: "2026-11-14",
      env: {
        DB: bindings.d1({ name: "pindo-sync-v3-development" }),
        SERVICE_ID: bindings.text("00000000-0000-4000-8000-000000000001"),
        LOG_CORE_ENABLED: bindings.text("development-only")
      },
      observability: {
        enabled: true, redactQueryString: true,
        traces: { enabled: true, headSamplingRate: 0.1 }
      }
    }
  };
});
