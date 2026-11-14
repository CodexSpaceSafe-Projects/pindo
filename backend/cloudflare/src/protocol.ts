export const MAX_COUNTER = 9_007_199_254_740_991;
export const MAX_BATCH_BYTES = 128 * 1024;
export const MAX_REQUEST_BYTES = 176 * 1024;
export const PAGE_SIZE = 8;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type ErrorCode = "authentication_required" | "unsupported_version" | "epoch_mismatch" |
  "batch_conflict" | "checkpoint_required" | "corrupt_data" | "quota_unavailable" |
  "storage_unavailable" | "maintenance" | "invalid_request" | "cursor_mismatch" |
  "not_found" | "unsupported_feature";

export class ProtocolError extends Error {
  constructor(readonly code: ErrorCode, readonly status: number) { super(code); }
}
export function uuid(value: unknown): string {
  if (typeof value !== "string" || !UUID.test(value)) throw new ProtocolError("invalid_request", 400);
  return value;
}
export function counter(value: string | null): number {
  if (value === null || !/^(0|[1-9][0-9]{0,15})$/.test(value)) throw new ProtocolError("invalid_request", 400);
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0) throw new ProtocolError("invalid_request", 400);
  return n;
}
export function aad(serviceID: string, vaultID: string, epoch: string, kind: string, objectID: string, artifactIDs: string[] = []): Uint8Array {
  [serviceID, vaultID, epoch, objectID].forEach(uuid);
  if (!["batch", "checkpoint", "chunk"].includes(kind) || artifactIDs.length > 50 ||
      artifactIDs.some((x, i) => !/^[0-9a-f]{64}$/.test(x) || (i > 0 && artifactIDs[i - 1] >= x))) {
    throw new ProtocolError("invalid_request", 400);
  }
  return new TextEncoder().encode(["PindoSync/v3", serviceID, vaultID, epoch, kind, objectID, artifactIDs.join(",")].join("\n"));
}
export async function sha256(value: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", value)), x => x.toString(16).padStart(2, "0")).join("");
}
export async function boundedJSON(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get("Content-Type")?.split(";")[0].trim() !== "application/json") throw new ProtocolError("invalid_request", 400);
  if (Number(request.headers.get("Content-Length")) > MAX_REQUEST_BYTES) throw new ProtocolError("invalid_request", 413);
  const reader = request.body?.getReader();
  if (!reader) throw new ProtocolError("invalid_request", 400);
  const pieces: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > MAX_REQUEST_BYTES) { await reader.cancel(); throw new ProtocolError("invalid_request", 413); }
      pieces.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const piece of pieces) { bytes.set(piece, offset); offset += piece.byteLength; }
    const result: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
    if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error();
    return result as Record<string, unknown>;
  } catch (e) {
    if (e instanceof ProtocolError) throw e;
    throw new ProtocolError("invalid_request", 400);
  } finally { reader.releaseLock(); }
}
export function ciphertext(value: unknown): Uint8Array {
  if (typeof value !== "string" || value.length > 174764 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new ProtocolError("corrupt_data", 400);
  try {
    const decoded = atob(value);
    // Combined AES-GCM bytes: 12-byte nonce, ciphertext, 16-byte tag.
    if (decoded.length < 29 || decoded.length > MAX_BATCH_BYTES || btoa(decoded) !== value) throw new Error();
    return Uint8Array.from(decoded, x => x.charCodeAt(0));
  } catch { throw new ProtocolError("corrupt_data", 400); }
}
