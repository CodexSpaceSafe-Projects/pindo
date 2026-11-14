ALTER TABLE vaults ADD COLUMN log_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE vaults ADD COLUMN log_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE vaults ADD COLUMN checkpoint_id TEXT;
ALTER TABLE commits ADD COLUMN artifact_ids TEXT NOT NULL DEFAULT '[]';
ALTER TABLE commits ADD COLUMN log_charge INTEGER NOT NULL DEFAULT 0;
UPDATE vaults SET log_count=(SELECT COUNT(*) FROM commits WHERE vault_id=vaults.id AND epoch=vaults.epoch);
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
ALTER TABLE vaults ADD COLUMN recovery_from_epoch TEXT;
ALTER TABLE vaults ADD COLUMN recovery_head INTEGER;
ALTER TABLE vaults ADD COLUMN recovery_floor INTEGER;
ALTER TABLE vaults ADD COLUMN key_check TEXT;

ALTER TABLE commits ADD COLUMN replay_bytes INTEGER NOT NULL DEFAULT 0;
