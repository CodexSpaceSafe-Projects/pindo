-- Add display names without changing device identities, tokens or sync history.
ALTER TABLE devices ADD COLUMN name TEXT NOT NULL DEFAULT '';
