import { RelayCore, RelayError } from "./core.mjs";
import { createEd25519Signer } from "./crypto.mjs";
import { D1RelayStore } from "./d1-store.mjs";
import { FCMPushSink } from "./fcm-push.mjs";

const MAX_REQUEST_BYTES = 65_536;

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extraHeaders,
    },
  });
}

function bearerToken(request) {
  const authorization = request.headers.get("authorization") || "";
  const match = /^Bearer ([A-Za-z0-9_-]+)$/.exec(authorization);
  if (!match) throw new RelayError(401, "unauthorized", "A bearer access token is required");
  return match[1];
}

async function jsonBody(request) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new RelayError(415, "unsupported_media_type", "Request body must be JSON");
  }
  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new RelayError(413, "request_too_large", "Request body exceeds 64 KiB");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_REQUEST_BYTES) {
    throw new RelayError(413, "request_too_large", "Request body exceeds 64 KiB");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new RelayError(400, "invalid_json", "Request body is not valid JSON");
  }
}

function requiredEnvironment(env) {
  const required = [
    "DB",
    "PUBLIC_RELAY_URL",
    "RELAY_SIGNING_PUBLIC_KEY",
    "RELAY_SIGNING_PRIVATE_KEY_PKCS8",
    "FIREBASE_SERVICE_ACCOUNT_JSON",
    "FIREBASE_PROJECT_ID",
  ];
  const missing = required.filter((key) => !env[key]);
  if (missing.length > 0) throw new Error(`Missing Worker bindings: ${missing.join(", ")}`);
}

export function createWorker({ fetchImpl = fetch, logger = console } = {}) {
  const coreByEnvironment = new WeakMap();

  async function coreFor(env) {
    requiredEnvironment(env);
    let corePromise = coreByEnvironment.get(env);
    if (!corePromise) {
      corePromise = (async () => {
        const clock = typeof env.DISCIPLINE_CLOCK === "function" ? env.DISCIPLINE_CLOCK : () => Date.now();
        const push = new FCMPushSink({
          serviceAccountJSON: env.FIREBASE_SERVICE_ACCOUNT_JSON,
          projectId: env.FIREBASE_PROJECT_ID,
          fetchImpl,
          clock,
        });
        return new RelayCore({
          store: new D1RelayStore(env.DB),
          push,
          signTransport: await createEd25519Signer(env.RELAY_SIGNING_PRIVATE_KEY_PKCS8),
          relayUrl: env.PUBLIC_RELAY_URL,
          relaySigningPublicKey: env.RELAY_SIGNING_PUBLIC_KEY,
          clock,
          makeKeyId: typeof env.DISCIPLINE_KEY_ID_GENERATOR === "function"
            ? env.DISCIPLINE_KEY_ID_GENERATOR
            : undefined,
        });
      })();
      coreByEnvironment.set(env, corePromise);
    }
    return corePromise;
  }

  async function route(request, env) {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return json({ ok: true, version: 1 });
    }

    const relay = await coreFor(env);

    if (request.method === "POST" && url.pathname === "/v1/pairings") {
      const offer = await jsonBody(request);
      return json(await relay.registerPairing({ offer, hostAccessToken: bearerToken(request) }), 201);
    }

    if (segments.length === 3 && segments[0] === "v1" && segments[1] === "pairings") {
      const pairingId = segments[2];
      if (request.method === "GET") {
        const hostId = url.searchParams.get("hostId") || "";
        return json(await relay.pairingStatus({
          pairingId,
          hostId,
          hostAccessToken: bearerToken(request),
        }));
      }
    }

    if (
      request.method === "POST"
      && segments.length === 4
      && segments[0] === "v1"
      && segments[1] === "pairings"
      && segments[3] === "claim"
    ) {
      const claim = await jsonBody(request);
      if (claim?.pairingId !== segments[2]) {
        throw new RelayError(400, "pairing_mismatch", "Pairing path and body do not match");
      }
      return json(await relay.claimPairing({
        claim,
        deviceAccessToken: bearerToken(request),
      }));
    }

    if (request.method === "POST" && url.pathname === "/v1/envelopes") {
      return json(await relay.publishEnvelope({
        envelope: await jsonBody(request),
        hostAccessToken: bearerToken(request),
      }), 202);
    }

    if (
      request.method === "DELETE"
      && segments.length === 5
      && segments[0] === "v1"
      && segments[1] === "hosts"
      && segments[3] === "devices"
    ) {
      return json(await relay.removeDeviceByHost({
        hostId: segments[2],
        deviceId: segments[4],
        hostAccessToken: bearerToken(request),
      }));
    }

    if (
      request.method === "GET"
      && segments.length === 4
      && segments[0] === "v1"
      && segments[1] === "devices"
      && segments[3] === "latest"
    ) {
      return json(await relay.latestEnvelope({
        deviceId: segments[2],
        deviceAccessToken: bearerToken(request),
      }));
    }

    if (
      request.method === "PUT"
      && segments.length === 4
      && segments[0] === "v1"
      && segments[1] === "devices"
      && segments[3] === "push-token"
    ) {
      const body = await jsonBody(request);
      if (!body || Object.keys(body).length !== 1 || typeof body.fcmToken !== "string") {
        throw new RelayError(400, "invalid_request", "Request must contain only fcmToken");
      }
      return json(await relay.updateDevicePushToken({
        deviceId: segments[2],
        deviceAccessToken: bearerToken(request),
        fcmToken: body.fcmToken,
      }));
    }

    if (
      request.method === "DELETE"
      && segments.length === 3
      && segments[0] === "v1"
      && segments[1] === "devices"
    ) {
      return json(await relay.unpairByDevice({
        deviceId: segments[2],
        deviceAccessToken: bearerToken(request),
      }));
    }

    return json({ error: { code: "not_found", message: "Route not found" } }, 404);
  }

  return {
    async fetch(request, env) {
      try {
        return await route(request, env);
      } catch (error) {
        if (error instanceof RelayError) {
          const details = error.details === undefined ? {} : { details: error.details };
          return json({ error: { code: error.code, message: error.message, ...details } }, error.status);
        }
        return json({ error: { code: "internal_error", message: "Internal relay error" } }, 500);
      }
    },

    async scheduled(_controller, env) {
      const result = await (await coreFor(env)).sweepOffline();
      logger.log(JSON.stringify({ event: "offline_sweep", sent: result.sent, failed: result.failed }));
      return result;
    },
  };
}

export default createWorker();
