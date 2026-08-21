function changes(result) {
  return Number(result?.meta?.changes ?? 0);
}

function hostFromRow(row) {
  if (!row) return undefined;
  return {
    hostId: row.host_id,
    hostName: row.host_name,
    hostPublicKey: row.host_public_key,
    hostAccessTokenHash: row.host_access_token_hash,
    createdAtMs: row.created_at_ms,
  };
}

function pairingFromRow(row) {
  if (!row) return undefined;
  return {
    pairingId: row.pairing_id,
    hostId: row.host_id,
    kdfSalt: row.kdf_salt,
    oneTimeTokenHash: row.one_time_token_hash,
    expiresAtMs: row.expires_at_ms,
    createdAtMs: row.created_at_ms,
    claimedDeviceId: row.claimed_device_id,
    claimedAtMs: row.claimed_at_ms,
  };
}

function deviceFromRow(row) {
  if (!row) return undefined;
  return {
    deviceId: row.device_id,
    hostId: row.host_id,
    deviceName: row.device_name,
    devicePublicKey: row.device_public_key,
    fcmToken: row.fcm_token,
    deviceAccessTokenHash: row.device_access_token_hash,
    keyId: row.key_id,
    pairedAtMs: row.paired_at_ms,
  };
}

function routeFromRow(row) {
  if (!row) return undefined;
  return {
    hostId: row.host_id,
    deviceId: row.device_id,
    keyId: row.key_id,
    lastSequence: row.last_sequence,
    lastHeartbeatMs: row.last_heartbeat_ms,
    offlineSent: row.offline_sent === 1,
    pendingSequence: row.pending_sequence,
    pendingKind: row.pending_kind,
    pendingAtMs: row.pending_at_ms,
  };
}

export class D1RelayStore {
  constructor(database) {
    this.database = database;
  }

  async getHost(hostId) {
    return hostFromRow(await this.database.prepare(
      `SELECT host_id, host_name, host_public_key, host_access_token_hash, created_at_ms
       FROM hosts WHERE host_id = ?1`,
    ).bind(hostId).first());
  }

  async createHost(host) {
    const result = await this.database.prepare(
      `INSERT OR IGNORE INTO hosts
       (host_id, host_name, host_public_key, host_access_token_hash, created_at_ms)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(
      host.hostId,
      host.hostName,
      host.hostPublicKey,
      host.hostAccessTokenHash,
      host.createdAtMs,
    ).run();
    return changes(result) === 1;
  }

  async getPairing(pairingId) {
    return pairingFromRow(await this.database.prepare(
      `SELECT pairing_id, host_id, kdf_salt, one_time_token_hash, expires_at_ms,
              created_at_ms, claimed_device_id, claimed_at_ms
       FROM pairings WHERE pairing_id = ?1`,
    ).bind(pairingId).first());
  }

  async createPairing(pairing) {
    const result = await this.database.prepare(
      `INSERT OR IGNORE INTO pairings
       (pairing_id, host_id, kdf_salt, one_time_token_hash, expires_at_ms,
        created_at_ms, claimed_device_id, claimed_at_ms)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL)`,
    ).bind(
      pairing.pairingId,
      pairing.hostId,
      pairing.kdfSalt,
      pairing.oneTimeTokenHash,
      pairing.expiresAtMs,
      pairing.createdAtMs,
    ).run();
    return changes(result) === 1;
  }

  async getDevice(deviceId) {
    return deviceFromRow(await this.database.prepare(
      `SELECT device_id, host_id, device_name, device_public_key, fcm_token,
              device_access_token_hash, key_id, paired_at_ms
       FROM devices WHERE device_id = ?1`,
    ).bind(deviceId).first());
  }

  async getDeviceForHost(hostId) {
    return deviceFromRow(await this.database.prepare(
      `SELECT device_id, host_id, device_name, device_public_key, fcm_token,
              device_access_token_hash, key_id, paired_at_ms
       FROM devices WHERE host_id = ?1`,
    ).bind(hostId).first());
  }

  async claimPairing(pairingId, device, route, claimedAtMs) {
    const insertDevice = this.database.prepare(
      `INSERT INTO devices
       (device_id, host_id, device_name, device_public_key, fcm_token,
        device_access_token_hash, key_id, paired_at_ms)
       SELECT ?1, p.host_id, ?2, ?3, ?4, ?5, ?6, ?7
       FROM pairings p
       WHERE p.pairing_id = ?8 AND p.claimed_device_id IS NULL`,
    ).bind(
      device.deviceId,
      device.deviceName,
      device.devicePublicKey,
      device.fcmToken,
      device.deviceAccessTokenHash,
      device.keyId,
      device.pairedAtMs,
      pairingId,
    );
    const insertRoute = this.database.prepare(
      `INSERT INTO routes
       (device_id, host_id, key_id, last_sequence, last_heartbeat_ms,
        offline_sent, pending_sequence, pending_kind, pending_at_ms)
       SELECT device_id, host_id, key_id, -1, NULL, 0, NULL, NULL, NULL
       FROM devices WHERE device_id = ?1`,
    ).bind(device.deviceId);
    const consumePairing = this.database.prepare(
      `UPDATE pairings
       SET claimed_device_id = ?1, claimed_at_ms = ?2, one_time_token_hash = NULL
       WHERE pairing_id = ?3 AND claimed_device_id IS NULL`,
    ).bind(device.deviceId, claimedAtMs, pairingId);

    try {
      const results = await this.database.batch([insertDevice, insertRoute, consumePairing]);
      return changes(results[0]) === 1 && changes(results[1]) === 1 && changes(results[2]) === 1;
    } catch (error) {
      const pairing = await this.getPairing(pairingId);
      const activeDevice = await this.getDeviceForHost(device.hostId);
      if ((pairing && pairing.claimedDeviceId !== null) || activeDevice) return false;
      throw error;
    }
  }

  async getRoute(deviceId) {
    return routeFromRow(await this.database.prepare(
      `SELECT host_id, device_id, key_id, last_sequence, last_heartbeat_ms,
              offline_sent, pending_sequence, pending_kind, pending_at_ms
       FROM routes WHERE device_id = ?1`,
    ).bind(deviceId).first());
  }

  async reserveDelivery(deviceId, keyId, sequence, kind, reservedAtMs, staleBeforeMs) {
    const result = await this.database.prepare(
      `UPDATE routes
       SET pending_sequence = ?1, pending_kind = ?2, pending_at_ms = ?5
       WHERE device_id = ?3 AND key_id = ?4
         AND (pending_sequence IS NULL OR pending_at_ms <= ?6)
         AND last_sequence < ?1`,
    ).bind(sequence, kind, deviceId, keyId, reservedAtMs, staleBeforeMs).run();
    if (changes(result) === 1) return { ok: true, route: await this.getRoute(deviceId) };

    const route = await this.getRoute(deviceId);
    if (!route || route.keyId !== keyId) return { ok: false, reason: "not_found" };
    if (route.pendingSequence !== null) return { ok: false, reason: "busy" };
    return { ok: false, reason: "replay", lastSequence: route.lastSequence };
  }

  async commitState(deviceId, sequence, heartbeatAtMs) {
    const result = await this.database.prepare(
      `UPDATE routes
       SET last_sequence = ?1, last_heartbeat_ms = ?2, offline_sent = 0,
           pending_sequence = NULL, pending_kind = NULL, pending_at_ms = NULL
       WHERE device_id = ?3 AND pending_sequence = ?1 AND pending_kind = 'state'`,
    ).bind(sequence, heartbeatAtMs, deviceId).run();
    return changes(result) === 1;
  }

  async commitOffline(deviceId, sequence) {
    const result = await this.database.prepare(
      `UPDATE routes
       SET last_sequence = ?1, offline_sent = 1,
           pending_sequence = NULL, pending_kind = NULL, pending_at_ms = NULL
       WHERE device_id = ?2 AND pending_sequence = ?1 AND pending_kind = 'offline'`,
    ).bind(sequence, deviceId).run();
    return changes(result) === 1;
  }

  async releaseDelivery(deviceId, sequence) {
    const result = await this.database.prepare(
      `UPDATE routes
       SET pending_sequence = NULL, pending_kind = NULL, pending_at_ms = NULL
       WHERE device_id = ?1 AND pending_sequence = ?2`,
    ).bind(deviceId, sequence).run();
    return changes(result) === 1;
  }

  async routesDueForOffline(cutoffMs, staleReservationBeforeMs) {
    const result = await this.database.prepare(
      `SELECT r.host_id, r.device_id, r.key_id, r.last_sequence,
              r.last_heartbeat_ms, r.offline_sent, r.pending_sequence,
              r.pending_kind, r.pending_at_ms, d.device_name, d.device_public_key, d.fcm_token,
              d.device_access_token_hash, d.paired_at_ms
       FROM routes r
       INNER JOIN devices d ON d.device_id = r.device_id
       WHERE r.last_heartbeat_ms IS NOT NULL
         AND r.last_heartbeat_ms <= ?1
         AND r.offline_sent = 0
         AND (r.pending_sequence IS NULL OR r.pending_at_ms <= ?2)`,
    ).bind(cutoffMs, staleReservationBeforeMs).all();
    return result.results.map((row) => ({
      route: routeFromRow(row),
      device: deviceFromRow(row),
    }));
  }

  async updateDevicePushToken(deviceId, fcmToken) {
    const result = await this.database.prepare(
      "UPDATE devices SET fcm_token = ?1 WHERE device_id = ?2",
    ).bind(fcmToken, deviceId).run();
    return changes(result) === 1;
  }

  async removeDevice(deviceId) {
    const result = await this.database.prepare(
      "DELETE FROM devices WHERE device_id = ?1",
    ).bind(deviceId).run();
    return changes(result) === 1;
  }

  async dumpPersistentState() {
    const table = async (name) => (await this.database.prepare(`SELECT * FROM ${name}`).all()).results;
    return {
      hosts: await table("hosts"),
      pairings: await table("pairings"),
      devices: await table("devices"),
      routes: await table("routes"),
    };
  }
}
