import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { RelayCore, RelayError } from "../src/core.mjs";
import {
  base64URLDecode,
  base64URLEncode,
  createEd25519Signer,
  transportSigningInput,
  verifyEd25519,
} from "../src/crypto.mjs";
import { MemoryRelayStore } from "../src/memory-store.mjs";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = resolve(testDirectory, "../../Protocol/fixtures");
const fixture = async (name) => JSON.parse(await readFile(resolve(fixtureDirectory, name), "utf8"));

function concatenate(...values) {
  const length = values.reduce((sum, value) => sum + value.length, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }
  return result;
}

function privateKeyPKCS8(seed) {
  const ed25519PKCS8Prefix = Uint8Array.from([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
    0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
  ]);
  return base64URLEncode(concatenate(ed25519PKCS8Prefix, base64URLDecode(seed)));
}

async function expectRelayError(action, code, status) {
  await assert.rejects(action, (error) => {
    assert.ok(error instanceof RelayError);
    assert.equal(error.code, code);
    assert.equal(error.status, status);
    return true;
  });
}

class CollectingPushSink {
  messages = [];

  async send(device, message) {
    this.messages.push({ device: structuredClone(device), message: structuredClone(message) });
  }
}

const offer = await fixture("pairing-offer.json");
const claim = await fixture("pairing-claim.json");
const envelope = await fixture("encrypted-envelope.json");
const vector = await fixture("crypto-vector-v1.json");
const fixedOffline = await fixture("transport-offline.json");

assert.equal(
  await verifyEd25519(vector.relaySigningPublicKey, vector.transportSigningInput, vector.transportSignature),
  true,
  "The Swift-generated Ed25519 fixture must verify in Web Crypto",
);
assert.equal(transportSigningInput(fixedOffline), vector.transportSigningInput);

const store = new MemoryRelayStore();
const push = new CollectingPushSink();
let nowMs = Date.parse("2026-08-20T14:32:18+08:00");
const signTransport = await createEd25519Signer(privateKeyPKCS8(vector.relaySigningPrivateKey));
const hostAccessToken = vector.hostPrivateKey;
const deviceAccessToken = vector.devicePrivateKey;
const relay = new RelayCore({
  store,
  push,
  signTransport,
  relayUrl: offer.relayUrl,
  relaySigningPublicKey: vector.relaySigningPublicKey,
  clock: () => nowMs,
  makeKeyId: () => vector.keyId,
});

await relay.registerPairing({ offer, hostAccessToken });
assert.equal((await relay.pairingStatus({ pairingId: offer.pairingId, hostId: offer.hostId, hostAccessToken })).status, "pending");

await expectRelayError(
  () => relay.claimPairing({ claim: { ...claim, oneTimeToken: hostAccessToken }, deviceAccessToken }),
  "unauthorized",
  401,
);

nowMs = Date.parse("2026-08-20T14:32:48+08:00");
const claimed = await relay.claimPairing({ claim, deviceAccessToken });
assert.equal(claimed.type, "pairing_claimed");
assert.equal(claimed.keyId, vector.keyId);
assert.equal((await relay.pairingStatus({ pairingId: offer.pairingId, hostId: offer.hostId, hostAccessToken })).status, "claimed");
await expectRelayError(() => relay.claimPairing({ claim, deviceAccessToken }), "pairing_used", 409);

const rotatedFCMToken = "rotated_fcm_token_for_relay_test";
await expectRelayError(
  () => relay.updateDevicePushToken({
    deviceId: claim.deviceId,
    deviceAccessToken: hostAccessToken,
    fcmToken: rotatedFCMToken,
  }),
  "unauthorized",
  401,
);
assert.deepEqual(await relay.updateDevicePushToken({
  deviceId: claim.deviceId,
  deviceAccessToken,
  fcmToken: rotatedFCMToken,
}), { updated: true });
assert.equal((await store.getDevice(claim.deviceId)).fcmToken, rotatedFCMToken);

nowMs = Date.parse("2026-08-20T14:32:18+08:00");
await relay.publishEnvelope({ envelope, hostAccessToken });
assert.equal(push.messages.length, 1);
assert.equal(push.messages[0].message.kind, "state");
assert.deepEqual(push.messages[0].message.envelope, envelope);
await expectRelayError(() => relay.publishEnvelope({ envelope, hostAccessToken }), "sequence_replay", 409);

const withTaskText = { ...envelope, taskText: "must never enter the relay" };
await expectRelayError(() => relay.publishEnvelope({ envelope: withTaskText, hostAccessToken }), "invalid_request", 400);

nowMs = Date.parse("2026-08-20T14:42:17.999+08:00");
assert.deepEqual(await relay.sweepOffline(), { sent: 0, failed: 0 });
nowMs = Date.parse("2026-08-20T14:42:18+08:00");
assert.deepEqual(await relay.sweepOffline(), { sent: 1, failed: 0 });
assert.equal(push.messages.length, 2);
const offlineEvent = push.messages[1].message.event;
assert.equal(push.messages[1].message.kind, "transport");
assert.equal(offlineEvent.sequence, 43);
assert.equal(offlineEvent.timeoutSeconds, 600);
assert.equal(await verifyEd25519(vector.relaySigningPublicKey, transportSigningInput(offlineEvent), offlineEvent.signature), true);
assert.deepEqual(await relay.sweepOffline(), { sent: 0, failed: 0 }, "Offline must be emitted only once per outage");

let sequenceConflict;
try {
  await relay.publishEnvelope({ envelope: { ...envelope, sequence: 43 }, hostAccessToken });
} catch (error) {
  sequenceConflict = error;
}
assert.equal(sequenceConflict?.code, "sequence_replay");
assert.equal(sequenceConflict?.details?.minimumSequence, 44, "Mac must be told how to advance after a relay-owned offline sequence");

nowMs = Date.parse("2026-08-20T14:42:20+08:00");
await relay.publishEnvelope({ envelope: { ...envelope, sequence: 44, sentAt: "2026-08-20T14:42:20+08:00" }, hostAccessToken });
assert.equal((await store.getRoute(claim.deviceId)).offlineSent, false, "A new encrypted heartbeat must re-arm offline detection");

const abandonedAtMs = nowMs;
assert.equal((await store.reserveDelivery(
  claim.deviceId,
  vector.keyId,
  45,
  "state",
  abandonedAtMs,
  abandonedAtMs - 60_000,
)).ok, true);
await expectRelayError(
  () => relay.publishEnvelope({ envelope: { ...envelope, sequence: 46 }, hostAccessToken }),
  "route_busy",
  409,
);
nowMs = abandonedAtMs + 60_000;
await relay.publishEnvelope({ envelope: { ...envelope, sequence: 46, sentAt: "2026-08-20T14:43:20+08:00" }, hostAccessToken });
assert.equal((await store.getRoute(claim.deviceId)).lastSequence, 46, "A stale delivery reservation must recover after 60 seconds");

const persistentJSON = JSON.stringify(await store.dumpPersistentState());
for (const forbidden of [
  offer.oneTimeToken,
  hostAccessToken,
  deviceAccessToken,
  envelope.nonce,
  envelope.ciphertext,
  vector.plaintext,
  "\"ciphertext\"",
  "\"nonce\"",
  "\"source\"",
  "\"status\"",
  "\"updatedAt\"",
  "taskText",
  "terminalOutput",
  "conversation",
]) {
  assert.equal(persistentJSON.includes(forbidden), false, `Persistent relay data leaked forbidden value: ${forbidden.slice(0, 24)}`);
}

await expectRelayError(
  () => relay.unpairByDevice({ deviceId: claim.deviceId, deviceAccessToken: hostAccessToken }),
  "unauthorized",
  401,
);
assert.deepEqual(await relay.unpairByDevice({ deviceId: claim.deviceId, deviceAccessToken }), { removed: true });
assert.equal(await store.getDevice(claim.deviceId), undefined);
assert.equal(await store.getRoute(claim.deviceId), undefined);

console.log("Discipline relay core self-test passed");
