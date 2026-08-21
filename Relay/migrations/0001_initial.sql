PRAGMA foreign_keys = ON;

CREATE TABLE hosts (
  host_id TEXT PRIMARY KEY,
  host_name TEXT NOT NULL,
  host_public_key TEXT NOT NULL,
  host_access_token_hash TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL
);

CREATE TABLE pairings (
  pairing_id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(host_id) ON DELETE CASCADE,
  kdf_salt TEXT NOT NULL,
  one_time_token_hash TEXT,
  expires_at_ms INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL,
  claimed_device_id TEXT,
  claimed_at_ms INTEGER
);

CREATE INDEX pairings_host_id ON pairings(host_id);

CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL UNIQUE REFERENCES hosts(host_id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  device_public_key TEXT NOT NULL,
  fcm_token TEXT NOT NULL,
  device_access_token_hash TEXT NOT NULL,
  key_id TEXT NOT NULL,
  paired_at_ms INTEGER NOT NULL
);

CREATE TABLE routes (
  device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
  host_id TEXT NOT NULL REFERENCES hosts(host_id) ON DELETE CASCADE,
  key_id TEXT NOT NULL,
  last_sequence INTEGER NOT NULL DEFAULT -1,
  last_heartbeat_ms INTEGER,
  offline_sent INTEGER NOT NULL DEFAULT 0 CHECK (offline_sent IN (0, 1)),
  pending_sequence INTEGER,
  pending_kind TEXT CHECK (pending_kind IN ('state', 'offline')),
  pending_at_ms INTEGER,
  CHECK (
    (pending_sequence IS NULL AND pending_kind IS NULL AND pending_at_ms IS NULL)
    OR (pending_sequence IS NOT NULL AND pending_kind IS NOT NULL AND pending_at_ms IS NOT NULL)
  )
);

CREATE INDEX routes_offline_scan ON routes(offline_sent, last_heartbeat_ms);
