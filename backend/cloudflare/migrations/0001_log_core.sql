-- Development log core. Provision vaults/devices through the operator channel.
-- No anonymous bootstrap API, content keys or plaintext business data.
CREATE TABLE vaults (
  id TEXT PRIMARY KEY,
  epoch TEXT NOT NULL,
  head INTEGER NOT NULL DEFAULT 0 CHECK(head BETWEEN 0 AND 9007199254740991),
  gc_floor INTEGER NOT NULL DEFAULT 0 CHECK(gc_floor BETWEEN 0 AND head),
  maintenance INTEGER NOT NULL DEFAULT 0 CHECK(maintenance IN (0,1)),
  charged_bytes INTEGER NOT NULL DEFAULT 0 CHECK(charged_bytes >= 0),
  byte_budget INTEGER NOT NULL DEFAULT 16777216 CHECK(byte_budget >= 0),
  batch_budget INTEGER NOT NULL DEFAULT 1000 CHECK(batch_budget BETWEEN 1 AND 9007199254740991)
) STRICT;
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL REFERENCES vaults(id),
  token_hash TEXT NOT NULL UNIQUE CHECK(length(token_hash) = 64),
  revoked_at INTEGER
) STRICT;
CREATE INDEX devices_vault ON devices(vault_id);
CREATE TABLE commits (
  vault_id TEXT NOT NULL REFERENCES vaults(id),
  epoch TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991),
  batch_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id),
  digest TEXT NOT NULL CHECK(length(digest) = 64),
  ciphertext TEXT NOT NULL CHECK(length(ciphertext) BETWEEN 40 AND 174764),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(vault_id, epoch, revision),
  UNIQUE(vault_id, epoch, batch_id)
) STRICT;
-- Receipts outlive commit GC and are never removed on a TTL.
CREATE TABLE receipts (
  vault_id TEXT NOT NULL REFERENCES vaults(id),
  epoch TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991),
  device_id TEXT NOT NULL REFERENCES devices(id),
  digest TEXT NOT NULL CHECK(length(digest) = 64),
  PRIMARY KEY(vault_id, epoch, batch_id)
) STRICT;
