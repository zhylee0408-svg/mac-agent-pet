function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

export class MemoryRelayStore {
  #hosts = new Map();
  #pairings = new Map();
  #devices = new Map();
  #routes = new Map();

  async getHost(hostId) {
    return clone(this.#hosts.get(hostId));
  }

  async createHost(host) {
    if (this.#hosts.has(host.hostId)) return false;
    this.#hosts.set(host.hostId, clone(host));
    return true;
  }

  async getPairing(pairingId) {
    return clone(this.#pairings.get(pairingId));
  }

  async createPairing(pairing) {
    if (this.#pairings.has(pairing.pairingId)) return false;
    this.#pairings.set(pairing.pairingId, clone(pairing));
    return true;
  }

  async getDevice(deviceId) {
    return clone(this.#devices.get(deviceId));
  }

  async getDeviceForHost(hostId) {
    for (const device of this.#devices.values()) {
      if (device.hostId === hostId) return clone(device);
    }
    return undefined;
  }

  async claimPairing(pairingId, device, route, claimedAtMs) {
    const pairing = this.#pairings.get(pairingId);
    if (!pairing || pairing.claimedDeviceId !== null) return false;
    if (this.#devices.has(device.deviceId)) return false;
    for (const existing of this.#devices.values()) {
      if (existing.hostId === device.hostId) return false;
    }

    pairing.claimedDeviceId = device.deviceId;
    pairing.claimedAtMs = claimedAtMs;
    pairing.oneTimeTokenHash = null;
    this.#devices.set(device.deviceId, clone(device));
    this.#routes.set(device.deviceId, clone(route));
    return true;
  }

  async getRoute(deviceId) {
    return clone(this.#routes.get(deviceId));
  }

  async reserveDelivery(deviceId, keyId, sequence, kind, reservedAtMs, staleBeforeMs) {
    const route = this.#routes.get(deviceId);
    if (!route || route.keyId !== keyId) return { ok: false, reason: "not_found" };
    if (route.pendingSequence !== null && route.pendingAtMs > staleBeforeMs) {
      return { ok: false, reason: "busy" };
    }
    if (sequence <= route.lastSequence) {
      return { ok: false, reason: "replay", lastSequence: route.lastSequence };
    }
    route.pendingSequence = sequence;
    route.pendingKind = kind;
    route.pendingAtMs = reservedAtMs;
    return { ok: true, route: clone(route) };
  }

  async commitState(deviceId, sequence, heartbeatAtMs, envelopeJson) {
    const route = this.#routes.get(deviceId);
    if (!route || route.pendingSequence !== sequence || route.pendingKind !== "state") return false;
    route.lastSequence = sequence;
    route.lastHeartbeatMs = heartbeatAtMs;
    route.offlineSent = false;
    route.pendingSequence = null;
    route.pendingKind = null;
    route.pendingAtMs = null;
    route.lastStateEnvelope = envelopeJson;
    return true;
  }

  async getLatestEnvelope(deviceId) {
    const route = this.#routes.get(deviceId);
    if (!route || typeof route.lastStateEnvelope !== "string") return null;
    try {
      return JSON.parse(route.lastStateEnvelope);
    } catch {
      return null;
    }
  }

  async commitOffline(deviceId, sequence) {
    const route = this.#routes.get(deviceId);
    if (!route || route.pendingSequence !== sequence || route.pendingKind !== "offline") return false;
    route.lastSequence = sequence;
    route.offlineSent = true;
    route.pendingSequence = null;
    route.pendingKind = null;
    route.pendingAtMs = null;
    return true;
  }

  async releaseDelivery(deviceId, sequence) {
    const route = this.#routes.get(deviceId);
    if (!route || route.pendingSequence !== sequence) return false;
    route.pendingSequence = null;
    route.pendingKind = null;
    route.pendingAtMs = null;
    return true;
  }

  async routesDueForOffline(cutoffMs, staleReservationBeforeMs) {
    const due = [];
    for (const route of this.#routes.values()) {
      if (
        route.lastHeartbeatMs !== null
        && route.lastHeartbeatMs <= cutoffMs
        && !route.offlineSent
        && (route.pendingSequence === null || route.pendingAtMs <= staleReservationBeforeMs)
      ) {
        const device = this.#devices.get(route.deviceId);
        if (device) due.push({ route: clone(route), device: clone(device) });
      }
    }
    return due;
  }

  async updateDevicePushToken(deviceId, fcmToken) {
    const device = this.#devices.get(deviceId);
    if (!device) return false;
    device.fcmToken = fcmToken;
    return true;
  }

  async removeDevice(deviceId) {
    const existed = this.#devices.delete(deviceId);
    this.#routes.delete(deviceId);
    return existed;
  }

  async dumpPersistentState() {
    return {
      hosts: [...this.#hosts.values()].map(clone),
      pairings: [...this.#pairings.values()].map(clone),
      devices: [...this.#devices.values()].map(clone),
      routes: [...this.#routes.values()].map(clone),
    };
  }
}
