import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  base64URLDecode,
  base64URLEncode,
  transportSigningInput,
  verifyEd25519,
} from "../src/crypto.mjs";
import { D1RelayStore } from "../src/d1-store.mjs";
import { fcmConstants } from "../src/fcm-push.mjs";
import { createWorker } from "../src/worker.mjs";
import { LocalD1Database } from "./local-d1.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const testDirectory = dirname(fileURLToPath(import.meta.url));
const relayDirectory = resolve(testDirectory, "..");
const fixtureDirectory = resolve(relayDirectory, "../Protocol/fixtures");
const fixture = async (name) => JSON.parse(await readFile(resolve(fixtureDirectory, name), "utf8"));

function concatenate(...values) {
  const result = new Uint8Array(values.reduce((sum, value) => sum + value.length, 0));
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }
  return result;
}

function ed25519PrivateKeyPKCS8(seed) {
  const prefix = Uint8Array.from([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
    0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
  ]);
  return base64URLEncode(concatenate(prefix, base64URLDecode(seed)));
}

function pem(value) {
  const base64 = Buffer.from(value).toString("base64");
  const lines = base64.match(/.{1,64}/g).join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
}

function authorization(token) {
  return { authorization: `Bearer ${token}` };
}

async function responseJSON(response, expectedStatus) {
  if (response.status !== expectedStatus) {
    const body = await response.text();
    assert.equal(response.status, expectedStatus, body);
  }
  return response.json();
}

const offer = await fixture("pairing-offer.json");
const claim = await fixture("pairing-claim.json");
const envelope = await fixture("encrypted-envelope.json");
const vector = await fixture("crypto-vector-v1.json");
let expectedFCMToken = claim.fcmToken;
const migration = (await readFile(resolve(relayDirectory, "migrations/0001_initial.sql"), "utf8"))
  + (await readFile(resolve(relayDirectory, "migrations/0002_latest_state.sql"), "utf8"));
const wrangler = JSON.parse(await readFile(resolve(relayDirectory, "wrangler.jsonc"), "utf8"));

assert.equal(wrangler.main, "src/worker.mjs");
assert.deepEqual(wrangler.triggers.crons, ["* * * * *"]);
assert.equal(wrangler.d1_databases[0].binding, "DB");
assert.equal(wrangler.d1_databases[0].migrations_dir, "migrations");
assert.equal(wrangler.observability.enabled, false);

const rsaKeys = await crypto.subtle.generateKey(
  {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: Uint8Array.from([1, 0, 1]),
    hash: "SHA-256",
  },
  true,
  ["sign", "verify"],
);
const rsaPrivatePKCS8 = await crypto.subtle.exportKey("pkcs8", rsaKeys.privateKey);
const serviceAccount = {
  type: "service_account",
  project_id: "discipline-test",
  private_key_id: "test-key",
  private_key: pem(new Uint8Array(rsaPrivatePKCS8)),
  client_email: "discipline-test@discipline-test.iam.gserviceaccount.com",
  token_uri: "https://oauth2.googleapis.com/token",
};

let oauthRequests = 0;
const fcmRequests = [];
async function fakeGoogleFetch(input, init) {
  const url = String(input);
  if (url === serviceAccount.token_uri) {
    oauthRequests += 1;
    const form = new URLSearchParams(String(init.body));
    assert.equal(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
    const assertion = form.get("assertion");
    const parts = assertion.split(".");
    assert.equal(parts.length, 3);
    const header = JSON.parse(decoder.decode(base64URLDecode(parts[0])));
    const claims = JSON.parse(decoder.decode(base64URLDecode(parts[1])));
    assert.deepEqual(header, { alg: "RS256", typ: "JWT" });
    assert.equal(claims.iss, serviceAccount.client_email);
    assert.equal(claims.scope, fcmConstants.scope);
    assert.equal(claims.aud, serviceAccount.token_uri);
    assert.equal(claims.exp - claims.iat, 3600);
    assert.equal(
      await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        rsaKeys.publicKey,
        base64URLDecode(parts[2]),
        encoder.encode(`${parts[0]}.${parts[1]}`),
      ),
      true,
    );
    return Response.json({ access_token: "oauth_test_access_token", expires_in: 3600 });
  }

  assert.equal(url, "https://fcm.googleapis.com/v1/projects/discipline-test/messages:send");
  assert.equal(init.headers.authorization, "Bearer oauth_test_access_token");
  const body = JSON.parse(init.body);
  assert.equal(body.message.fid, expectedFCMToken);
  assert.equal(body.message.token, undefined);
  assert.equal(body.message.android.priority, "HIGH");
  assert.equal(body.message.android.ttl, "600s");
  // 有意不设 collapse_key：ColorOS 投递延迟时中间状态不能被合并丢弃。
  assert.equal(body.message.android.collapse_key, undefined);
  assert.ok(Object.values(body.message.data).every((value) => typeof value === "string"));
  fcmRequests.push(body);
  return Response.json({ name: `projects/discipline-test/messages/${fcmRequests.length}` });
}

const database = new LocalD1Database(migration);
const hostAccessToken = vector.hostPrivateKey;
const deviceAccessToken = vector.devicePrivateKey;
let nowMs = Date.parse("2026-08-20T14:32:18+08:00");
const environment = {
  DB: database,
  PUBLIC_RELAY_URL: offer.relayUrl,
  RELAY_SIGNING_PUBLIC_KEY: vector.relaySigningPublicKey,
  RELAY_SIGNING_PRIVATE_KEY_PKCS8: ed25519PrivateKeyPKCS8(vector.relaySigningPrivateKey),
  FIREBASE_SERVICE_ACCOUNT_JSON: JSON.stringify(serviceAccount),
  FIREBASE_PROJECT_ID: serviceAccount.project_id,
  DISCIPLINE_CLOCK: () => nowMs,
  DISCIPLINE_KEY_ID_GENERATOR: () => vector.keyId,
};
const worker = createWorker({ fetchImpl: fakeGoogleFetch, logger: { log() {} } });

function request(method, path, { token, body } = {}) {
  const headers = token ? authorization(token) : {};
  if (body !== undefined) headers["content-type"] = "application/json";
  return new Request(`${offer.relayUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

assert.deepEqual(
  await responseJSON(await worker.fetch(request("GET", "/v1/health"), environment), 200),
  { ok: true, version: 1 },
);
await responseJSON(
  await worker.fetch(request("POST", "/v1/pairings", { token: hostAccessToken, body: offer }), environment),
  201,
);
assert.equal(
  (await responseJSON(
    await worker.fetch(request("GET", `/v1/pairings/${offer.pairingId}?hostId=${offer.hostId}`, { token: hostAccessToken }), environment),
    200,
  )).status,
  "pending",
);
await responseJSON(
  await worker.fetch(request("POST", `/v1/pairings/${offer.pairingId}/claim`, { token: deviceAccessToken, body: claim }), environment),
  200,
);

expectedFCMToken = "rotated_fcm_token_for_worker_test";
await responseJSON(
  await worker.fetch(request("PUT", `/v1/devices/${claim.deviceId}/push-token`, {
    token: deviceAccessToken,
    body: { fcmToken: expectedFCMToken },
  }), environment),
  200,
);
assert.equal((await new D1RelayStore(database).getDevice(claim.deviceId)).fcmToken, expectedFCMToken);

await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", { token: hostAccessToken, body: envelope }), environment),
  202,
);
await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", {
    token: hostAccessToken,
    body: { ...envelope, sequence: 43, sentAt: "2026-08-20T14:32:19+08:00" },
  }), environment),
  202,
);
assert.equal(oauthRequests, 1, "FCM OAuth access token must be cached");
assert.equal(fcmRequests.length, 2);
assert.equal(fcmRequests[0].message.data.kind, "state");
assert.deepEqual(JSON.parse(fcmRequests[0].message.data.payload), envelope);

// 拉取制：GET /v1/devices/:id/latest 应返回最新已提交的 envelope（sequence 43）。
const latest = await responseJSON(
  await worker.fetch(request("GET", `/v1/devices/${claim.deviceId}/latest`, { token: deviceAccessToken }), environment),
  200,
);
assert.equal(latest.sequence, 43);
assert.equal(latest.deviceId, claim.deviceId);
assert.equal(latest.hostId, envelope.hostId);
assert.equal(latest.keyId, envelope.keyId);

nowMs = Date.parse("2026-08-20T14:42:19+08:00");
assert.deepEqual(await worker.scheduled({ scheduledTime: nowMs }, environment), { sent: 1, failed: 0 });
assert.equal(fcmRequests.length, 3);
assert.equal(fcmRequests[2].message.data.kind, "transport");
const offlineEvent = JSON.parse(fcmRequests[2].message.data.payload);
assert.equal(offlineEvent.sequence, 44);
assert.equal(offlineEvent.timeoutSeconds, 600);
assert.equal(
  await verifyEd25519(vector.relaySigningPublicKey, transportSigningInput(offlineEvent), offlineEvent.signature),
  true,
);

const replay = await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", {
    token: hostAccessToken,
    body: { ...envelope, sequence: 44 },
  }), environment),
  409,
);
assert.equal(replay.error.code, "sequence_replay");
assert.equal(replay.error.details.minimumSequence, 45);

const d1Store = new D1RelayStore(database);
const abandonedAtMs = nowMs;
assert.equal((await d1Store.reserveDelivery(
  claim.deviceId,
  vector.keyId,
  45,
  "state",
  abandonedAtMs,
  abandonedAtMs - 60_000,
)).ok, true);
const busy = await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", {
    token: hostAccessToken,
    body: { ...envelope, sequence: 46 },
  }), environment),
  409,
);
assert.equal(busy.error.code, "route_busy");
nowMs = abandonedAtMs + 60_000;
await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", {
    token: hostAccessToken,
    body: { ...envelope, sequence: 46, sentAt: "2026-08-20T14:43:19+08:00" },
  }), environment),
  202,
);
assert.equal((await d1Store.getRoute(claim.deviceId)).lastSequence, 46);
assert.equal(oauthRequests, 1);
assert.equal(fcmRequests.length, 4);

const forbiddenBody = await responseJSON(
  await worker.fetch(request("POST", "/v1/envelopes", {
    token: hostAccessToken,
    body: { ...envelope, sequence: 47, taskText: "private task" },
  }), environment),
  400,
);
assert.equal(forbiddenBody.error.code, "invalid_request");

const persisted = JSON.stringify(await d1Store.dumpPersistentState());
for (const forbidden of [
  offer.oneTimeToken,
  hostAccessToken,
  deviceAccessToken,
  vector.plaintext,
  "\"status\"",
  "\"source\"",
  "taskText",
]) {
  assert.equal(persisted.includes(forbidden), false, `D1 persisted forbidden data: ${forbidden.slice(0, 24)}`);
}

await responseJSON(
  await worker.fetch(request("DELETE", `/v1/devices/${claim.deviceId}`, { token: deviceAccessToken }), environment),
  200,
);
assert.equal(
  (await responseJSON(
    await worker.fetch(request("GET", `/v1/pairings/${offer.pairingId}?hostId=${offer.hostId}`, { token: hostAccessToken }), environment),
    200,
  )).status,
  "removed",
);

database.close();
console.log("Discipline Worker/D1/FCM adapter self-test passed");
