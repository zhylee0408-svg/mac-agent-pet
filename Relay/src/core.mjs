import {
  base64URLDecode,
  constantTimeEqual,
  tokenDigest,
  transportSigningInput,
} from "./crypto.mjs";

const IDENTIFIER = /^[A-Za-z0-9_-]{1,80}$/;
const SOURCE_IDENTIFIER = /^[a-z][a-z0-9_-]{0,31}$/;
const ALGORITHM = "X25519-HKDF-SHA256-A256GCM";
const OFFLINE_TIMEOUT_MS = 600_000;
const DELIVERY_RESERVATION_TIMEOUT_MS = 60_000;

export class RelayError extends Error {
  constructor(status, code, message, details = undefined) {
    super(message);
    this.name = "RelayError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function fail(status, code, message, details) {
  throw new RelayError(status, code, message, details);
}

function requireCondition(condition, status, code, message) {
  if (!condition) fail(status, code, message);
}

function exactKeys(value, keys, label) {
  requireCondition(value && typeof value === "object" && !Array.isArray(value), 400, "invalid_request", `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  requireCondition(
    actual.length === expected.length && actual.every((key, index) => key === expected[index]),
    400,
    "invalid_request",
    `${label} contains missing or unexpected fields`,
  );
}

function validTimestamp(value) {
  return typeof value === "string" && value.includes("T") && Number.isFinite(Date.parse(value));
}

function validIdentifier(value) {
  return typeof value === "string" && IDENTIFIER.test(value);
}

function decodedLength(value) {
  try {
    return base64URLDecode(value).length;
  } catch {
    return -1;
  }
}

function validateAccessToken(value, label) {
  requireCondition(decodedLength(value) >= 32, 400, "weak_access_token", `${label} must contain at least 32 random bytes`);
}

function validateFCMToken(value) {
  requireCondition(typeof value === "string" && value.length >= 16 && value.length <= 4096, 400, "invalid_fcm_token", "Invalid FCM token");
}

function validateOffer(offer, nowMs, relayUrl, relaySigningPublicKey) {
  exactKeys(offer, [
    "version", "type", "relayUrl", "pairingId", "oneTimeToken", "hostId", "hostName",
    "hostPublicKey", "kdfSalt", "relaySigningPublicKey", "expiresAt",
  ], "pairing offer");
  requireCondition(offer.version === 1 && offer.type === "pairing_offer", 400, "invalid_offer", "Unsupported pairing offer version or type");
  requireCondition(offer.relayUrl === relayUrl && offer.relayUrl.startsWith("https://"), 400, "invalid_offer", "Pairing offer relay URL mismatch");
  requireCondition(validIdentifier(offer.pairingId) && validIdentifier(offer.hostId), 400, "invalid_offer", "Invalid pairing or host ID");
  requireCondition(typeof offer.hostName === "string" && offer.hostName.length >= 1 && offer.hostName.length <= 80, 400, "invalid_offer", "Invalid host name");
  requireCondition(decodedLength(offer.oneTimeToken) >= 32, 400, "invalid_offer", "Pairing token must contain at least 32 random bytes");
  requireCondition(decodedLength(offer.hostPublicKey) === 32, 400, "invalid_offer", "Host public key must be 32 bytes");
  requireCondition(decodedLength(offer.kdfSalt) === 32, 400, "invalid_offer", "KDF salt must be 32 bytes");
  requireCondition(offer.relaySigningPublicKey === relaySigningPublicKey && decodedLength(offer.relaySigningPublicKey) === 32, 400, "invalid_offer", "Relay signing public key mismatch");
  requireCondition(validTimestamp(offer.expiresAt), 400, "invalid_offer", "Invalid pairing expiry");
  const expiryMs = Date.parse(offer.expiresAt);
  requireCondition(expiryMs > nowMs && expiryMs - nowMs <= 300_000, 400, "invalid_offer", "Pairing offer must expire within five minutes");
  return expiryMs;
}

function validateClaim(claim) {
  exactKeys(claim, [
    "version", "type", "pairingId", "oneTimeToken", "deviceId", "deviceName",
    "devicePublicKey", "fcmToken",
  ], "pairing claim");
  requireCondition(claim.version === 1 && claim.type === "pairing_claim", 400, "invalid_claim", "Unsupported pairing claim version or type");
  requireCondition(validIdentifier(claim.pairingId) && validIdentifier(claim.deviceId), 400, "invalid_claim", "Invalid pairing or device ID");
  requireCondition(decodedLength(claim.oneTimeToken) >= 32, 400, "invalid_claim", "Pairing token must contain at least 32 random bytes");
  requireCondition(typeof claim.deviceName === "string" && claim.deviceName.length >= 1 && claim.deviceName.length <= 80, 400, "invalid_claim", "Invalid device name");
  requireCondition(decodedLength(claim.devicePublicKey) === 32, 400, "invalid_claim", "Device public key must be 32 bytes");
  validateFCMToken(claim.fcmToken);
}

function validateEnvelope(envelope) {
  exactKeys(envelope, [
    "version", "algorithm", "hostId", "deviceId", "keyId", "sequence", "sentAt",
    "nonce", "ciphertext",
  ], "encrypted envelope");
  requireCondition(envelope.version === 1 && envelope.algorithm === ALGORITHM, 400, "invalid_envelope", "Unsupported encrypted envelope");
  requireCondition(validIdentifier(envelope.hostId) && validIdentifier(envelope.deviceId) && validIdentifier(envelope.keyId), 400, "invalid_envelope", "Invalid envelope identity");
  requireCondition(Number.isSafeInteger(envelope.sequence) && envelope.sequence >= 0, 400, "invalid_envelope", "Invalid envelope sequence");
  requireCondition(validTimestamp(envelope.sentAt), 400, "invalid_envelope", "Invalid envelope timestamp");
  requireCondition(decodedLength(envelope.nonce) === 12, 400, "invalid_envelope", "AES-GCM nonce must be 12 bytes");
  requireCondition(decodedLength(envelope.ciphertext) > 16, 400, "invalid_envelope", "Ciphertext must include data and a 16-byte tag");
}

export class RelayCore {
  constructor({ store, push, signTransport, relayUrl, relaySigningPublicKey, clock = () => Date.now(), makeKeyId = () => crypto.randomUUID().replaceAll("-", "") }) {
    this.store = store;
    this.push = push;
    this.signTransport = signTransport;
    this.relayUrl = relayUrl;
    this.relaySigningPublicKey = relaySigningPublicKey;
    this.clock = clock;
    this.makeKeyId = makeKeyId;
  }

  async #authenticateHost(hostId, accessToken) {
    validateAccessToken(accessToken, "Host access token");
    const host = await this.store.getHost(hostId);
    if (!host) fail(404, "host_not_found", "Host is not registered");
    const digest = await tokenDigest("host", hostId, accessToken);
    if (!constantTimeEqual(host.hostAccessTokenHash, digest)) fail(401, "unauthorized", "Invalid host access token");
    return host;
  }

  async #authenticateDevice(deviceId, accessToken) {
    validateAccessToken(accessToken, "Device access token");
    const device = await this.store.getDevice(deviceId);
    if (!device) fail(404, "device_not_found", "Device is not paired");
    const digest = await tokenDigest("device", deviceId, accessToken);
    if (!constantTimeEqual(device.deviceAccessTokenHash, digest)) fail(401, "unauthorized", "Invalid device access token");
    return device;
  }

  async registerPairing({ offer, hostAccessToken }) {
    const nowMs = this.clock();
    const expiryMs = validateOffer(offer, nowMs, this.relayUrl, this.relaySigningPublicKey);
    validateAccessToken(hostAccessToken, "Host access token");

    const hostAccessTokenHash = await tokenDigest("host", offer.hostId, hostAccessToken);
    const existingHost = await this.store.getHost(offer.hostId);
    if (existingHost && !constantTimeEqual(existingHost.hostAccessTokenHash, hostAccessTokenHash)) {
      fail(401, "unauthorized", "Host ID is already registered with another access token");
    }
    if (existingHost && existingHost.hostPublicKey !== offer.hostPublicKey) {
      fail(409, "host_key_conflict", "Host ID is already registered with another public key");
    }

    if (!existingHost) {
      const created = await this.store.createHost({
        hostId: offer.hostId,
        hostName: offer.hostName,
        hostPublicKey: offer.hostPublicKey,
        hostAccessTokenHash,
        createdAtMs: nowMs,
      });
      if (!created) fail(409, "host_conflict", "Host registration raced with another request");
    }

    const oneTimeTokenHash = await tokenDigest("pairing", offer.pairingId, offer.oneTimeToken);
    const created = await this.store.createPairing({
      pairingId: offer.pairingId,
      hostId: offer.hostId,
      kdfSalt: offer.kdfSalt,
      oneTimeTokenHash,
      expiresAtMs: expiryMs,
      createdAtMs: nowMs,
      claimedDeviceId: null,
      claimedAtMs: null,
    });
    if (!created) fail(409, "pairing_conflict", "Pairing ID already exists");
    return structuredClone(offer);
  }

  async pairingStatus({ pairingId, hostId, hostAccessToken }) {
    await this.#authenticateHost(hostId, hostAccessToken);
    const pairing = await this.store.getPairing(pairingId);
    if (!pairing || pairing.hostId !== hostId) fail(404, "pairing_not_found", "Pairing was not found for this host");
    if (pairing.claimedDeviceId === null) {
      return {
        status: this.clock() > pairing.expiresAtMs ? "expired" : "pending",
        expiresAt: new Date(pairing.expiresAtMs).toISOString(),
      };
    }
    const device = await this.store.getDevice(pairing.claimedDeviceId);
    if (!device) {
      return { status: "removed", deviceId: pairing.claimedDeviceId };
    }
    return {
      status: "claimed",
      claimed: {
        version: 1,
        type: "pairing_claimed",
        pairingId,
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        devicePublicKey: device.devicePublicKey,
        keyId: device.keyId,
        claimedAt: new Date(pairing.claimedAtMs).toISOString(),
      },
    };
  }

  async claimPairing({ claim, deviceAccessToken }) {
    validateClaim(claim);
    validateAccessToken(deviceAccessToken, "Device access token");
    const pairing = await this.store.getPairing(claim.pairingId);
    if (!pairing) fail(404, "pairing_not_found", "Pairing does not exist");
    if (pairing.claimedDeviceId !== null || pairing.oneTimeTokenHash === null) fail(409, "pairing_used", "Pairing token has already been used");
    if (this.clock() > pairing.expiresAtMs) fail(410, "pairing_expired", "Pairing token has expired");

    const oneTimeTokenHash = await tokenDigest("pairing", claim.pairingId, claim.oneTimeToken);
    if (!constantTimeEqual(pairing.oneTimeTokenHash, oneTimeTokenHash)) fail(401, "unauthorized", "Invalid one-time pairing token");
    if (await this.store.getDeviceForHost(pairing.hostId)) fail(409, "device_limit", "This host already has its v1 device");

    const nowMs = this.clock();
    const keyId = this.makeKeyId();
    requireCondition(validIdentifier(keyId), 500, "invalid_key_id", "Key ID generator returned an invalid ID");
    const deviceAccessTokenHash = await tokenDigest("device", claim.deviceId, deviceAccessToken);
    const device = {
      deviceId: claim.deviceId,
      hostId: pairing.hostId,
      deviceName: claim.deviceName,
      devicePublicKey: claim.devicePublicKey,
      fcmToken: claim.fcmToken,
      deviceAccessTokenHash,
      keyId,
      pairedAtMs: nowMs,
    };
    const route = {
      hostId: pairing.hostId,
      deviceId: claim.deviceId,
      keyId,
      lastSequence: -1,
      lastHeartbeatMs: null,
      offlineSent: false,
      pendingSequence: null,
      pendingKind: null,
      pendingAtMs: null,
    };
    const claimed = await this.store.claimPairing(claim.pairingId, device, route, nowMs);
    if (!claimed) fail(409, "pairing_race", "Pairing was claimed concurrently");

    return {
      version: 1,
      type: "pairing_claimed",
      pairingId: claim.pairingId,
      deviceId: claim.deviceId,
      deviceName: claim.deviceName,
      devicePublicKey: claim.devicePublicKey,
      keyId,
      claimedAt: new Date(nowMs).toISOString(),
    };
  }

  async publishEnvelope({ envelope, hostAccessToken }) {
    validateEnvelope(envelope);
    await this.#authenticateHost(envelope.hostId, hostAccessToken);
    const device = await this.store.getDevice(envelope.deviceId);
    if (!device || device.hostId !== envelope.hostId) fail(404, "route_not_found", "No paired route exists for this envelope");

    const nowMs = this.clock();
    const reservation = await this.store.reserveDelivery(
      envelope.deviceId,
      envelope.keyId,
      envelope.sequence,
      "state",
      nowMs,
      nowMs - DELIVERY_RESERVATION_TIMEOUT_MS,
    );
    if (!reservation.ok) {
      if (reservation.reason === "replay") {
        fail(409, "sequence_replay", "Sequence was already used", { minimumSequence: reservation.lastSequence + 1 });
      }
      if (reservation.reason === "busy") fail(409, "route_busy", "Another delivery is in progress");
      fail(404, "route_not_found", "No matching device key route exists");
    }

    try {
      await this.push.send(device, { kind: "state", envelope: structuredClone(envelope) });
      const committed = await this.store.commitState(envelope.deviceId, envelope.sequence, nowMs);
      if (!committed) fail(500, "commit_failed", "State delivery could not be committed");
    } catch (error) {
      await this.store.releaseDelivery(envelope.deviceId, envelope.sequence);
      if (error instanceof RelayError) throw error;
      const name = error instanceof Error ? error.name : typeof error;
      const status = error instanceof Error && typeof error.status === "number"
        ? ` HTTP ${error.status}`
        : "";
      const detail = `${name}${status}`;
      console.error("fcm_push_failed", JSON.stringify({
        name,
        status: error instanceof Error ? error.status : undefined,
        message: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
      }));
      fail(502, "push_failed", `Encrypted state could not be forwarded (${detail})`);
    }
    return { accepted: true, sequence: envelope.sequence };
  }

  async sweepOffline() {
    const nowMs = this.clock();
    const due = await this.store.routesDueForOffline(
      nowMs - OFFLINE_TIMEOUT_MS,
      nowMs - DELIVERY_RESERVATION_TIMEOUT_MS,
    );
    const result = { sent: 0, failed: 0 };

    for (const { route, device } of due) {
      const sequence = route.lastSequence + 1;
      const reservation = await this.store.reserveDelivery(
        device.deviceId,
        route.keyId,
        sequence,
        "offline",
        nowMs,
        nowMs - DELIVERY_RESERVATION_TIMEOUT_MS,
      );
      if (!reservation.ok) continue;
      const event = {
        version: 1,
        type: "transport",
        event: "offline",
        hostId: route.hostId,
        deviceId: route.deviceId,
        sequence,
        observedAt: new Date(nowMs).toISOString(),
        timeoutSeconds: OFFLINE_TIMEOUT_MS / 1000,
        reason: "heartbeat_timeout",
        signature: "",
      };
      try {
        event.signature = await this.signTransport(transportSigningInput(event));
        await this.push.send(device, { kind: "transport", event });
        const committed = await this.store.commitOffline(device.deviceId, sequence);
        if (!committed) fail(500, "commit_failed", "Offline delivery could not be committed");
        result.sent += 1;
      } catch {
        await this.store.releaseDelivery(device.deviceId, sequence);
        result.failed += 1;
      }
    }
    return result;
  }

  async removeDeviceByHost({ hostId, deviceId, hostAccessToken }) {
    await this.#authenticateHost(hostId, hostAccessToken);
    const device = await this.store.getDevice(deviceId);
    if (!device || device.hostId !== hostId) fail(404, "device_not_found", "Device is not paired to this host");
    await this.store.removeDevice(deviceId);
    return { removed: true };
  }

  async updateDevicePushToken({ deviceId, deviceAccessToken, fcmToken }) {
    validateFCMToken(fcmToken);
    await this.#authenticateDevice(deviceId, deviceAccessToken);
    const updated = await this.store.updateDevicePushToken(deviceId, fcmToken);
    if (!updated) fail(404, "device_not_found", "Device is not paired");
    return { updated: true };
  }

  async unpairByDevice({ deviceId, deviceAccessToken }) {
    await this.#authenticateDevice(deviceId, deviceAccessToken);
    await this.store.removeDevice(deviceId);
    return { removed: true };
  }
}

export const relayConstants = Object.freeze({
  algorithm: ALGORITHM,
  offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
  deliveryReservationTimeoutMs: DELIVERY_RESERVATION_TIMEOUT_MS,
  sourceIdentifier: SOURCE_IDENTIFIER,
});
