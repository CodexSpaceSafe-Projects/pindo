-- Complete schema for a fresh encrypted-sync service. No upgrade path.
CREATE TABLE vaults (
  id TEXT PRIMARY KEY,
  epoch TEXT NOT NULL,
  head INTEGER NOT NULL DEFAULT 0 CHECK(head BETWEEN 0 AND 9007199254740991),
  gc_floor INTEGER NOT NULL DEFAULT 0 CHECK(gc_floor BETWEEN 0 AND head),
  maintenance INTEGER NOT NULL DEFAULT 0 CHECK(maintenance IN (0,1)),
  charged_bytes INTEGER NOT NULL DEFAULT 0 CHECK(charged_bytes >= 0),
  byte_budget INTEGER NOT NULL DEFAULT 16777216 CHECK(byte_budget >= 0),
  batch_budget INTEGER NOT NULL DEFAULT 1000 CHECK(batch_budget BETWEEN 1 AND 9007199254740991),
  log_count INTEGER NOT NULL DEFAULT 0,
  log_bytes INTEGER NOT NULL DEFAULT 0,
  checkpoint_id TEXT,
  recovery_from_epoch TEXT,
  recovery_head INTEGER,
  recovery_floor INTEGER,
  key_check TEXT
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
  artifact_ids TEXT NOT NULL DEFAULT '[]',
  log_charge INTEGER NOT NULL DEFAULT 0,
  replay_bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(vault_id, epoch, revision),
  UNIQUE(vault_id, epoch, batch_id)
) STRICT;
-- Receipts outlive commit GC so an interrupted upload remains idempotent.
CREATE TABLE receipts (
  vault_id TEXT NOT NULL REFERENCES vaults(id),
  epoch TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991),
  device_id TEXT NOT NULL REFERENCES devices(id),
  digest TEXT NOT NULL CHECK(length(digest) = 64),
  PRIMARY KEY(vault_id, epoch, batch_id)
) STRICT;
CREATE TABLE artifacts (
  vault_id TEXT NOT NULL REFERENCES vaults(id), epoch TEXT NOT NULL, digest TEXT NOT NULL,
  object_id TEXT NOT NULL, ciphertext TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes BETWEEN 29 AND 65536),
  charge INTEGER NOT NULL, created_at INTEGER NOT NULL, lease_until INTEGER NOT NULL,
  PRIMARY KEY(vault_id,epoch,digest), UNIQUE(vault_id,epoch,object_id)
) STRICT;
CREATE TABLE commit_artifacts (
  vault_id TEXT NOT NULL, epoch TEXT NOT NULL, revision INTEGER NOT NULL, digest TEXT NOT NULL,
  PRIMARY KEY(vault_id,epoch,revision,digest)
) STRICT;
CREATE INDEX commit_artifact_digest ON commit_artifacts(vault_id,epoch,digest);
CREATE TABLE checkpoints (
  vault_id TEXT NOT NULL REFERENCES vaults(id), epoch TEXT NOT NULL, id TEXT NOT NULL, covered INTEGER NOT NULL,
  ciphertext TEXT NOT NULL, artifact_ids TEXT NOT NULL, digest TEXT NOT NULL, charge INTEGER NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY(vault_id,epoch,id), UNIQUE(vault_id,epoch,covered)
) STRICT;
CREATE TABLE checkpoint_artifacts (
  vault_id TEXT NOT NULL, epoch TEXT NOT NULL, checkpoint_id TEXT NOT NULL, digest TEXT NOT NULL,
  PRIMARY KEY(vault_id,epoch,checkpoint_id,digest)
) STRICT;
CREATE INDEX checkpoint_artifact_digest ON checkpoint_artifacts(vault_id,epoch,digest);
CREATE TABLE leases (
  id TEXT PRIMARY KEY, vault_id TEXT NOT NULL REFERENCES vaults(id), epoch TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id), floor INTEGER NOT NULL, expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX lease_floor ON leases(vault_id,epoch,expires_at,floor);
CREATE TABLE pairing (
  id TEXT PRIMARY KEY, vault_id TEXT NOT NULL REFERENCES vaults(id), epoch TEXT NOT NULL,
  code_hash TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES devices(id), expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, consumed_device TEXT, consumed_hash TEXT
) STRICT;
CREATE TABLE service_state (id INTEGER PRIMARY KEY CHECK(id=1), bootstrapped INTEGER NOT NULL DEFAULT 0) STRICT;
INSERT INTO service_state(id,bootstrapped) VALUES(1,0);
CREATE TABLE mutations (id TEXT PRIMARY KEY, vault_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL) STRICT;
