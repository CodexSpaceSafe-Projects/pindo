-- Shared encrypted history does not belong to a device registration.
ALTER TABLE commits DROP COLUMN device_id;
ALTER TABLE receipts DROP COLUMN device_id;
-- Remove legacy disabled registrations and their credentials, not shared data.
DELETE FROM leases WHERE device_id IN (SELECT id FROM devices WHERE revoked_at IS NOT NULL);
DELETE FROM pairing WHERE created_by IN (SELECT id FROM devices WHERE revoked_at IS NOT NULL)
  OR consumed_device IN (SELECT id FROM devices WHERE revoked_at IS NOT NULL);
DELETE FROM devices WHERE revoked_at IS NOT NULL;
ALTER TABLE devices DROP COLUMN revoked_at;
