import { base64URLEncode } from "./crypto.mjs";

const encoder = new TextEncoder();
const FIREBASE_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

export class FCMPushError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.name = "FCMPushError";
    this.status = status;
  }
}

function pemPrivateKey(value) {
  if (typeof value !== "string") throw new FCMPushError("Firebase private key is missing", 500);
  const base64 = value
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replaceAll(/\s/g, "");
  try {
    const binary = atob(base64);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new FCMPushError("Firebase private key is invalid", 500);
  }
}

function jwtPart(value) {
  return base64URLEncode(encoder.encode(JSON.stringify(value)));
}

export class FCMPushSink {
  constructor({ serviceAccountJSON, projectId, fetchImpl = fetch, clock = () => Date.now() }) {
    let serviceAccount;
    try {
      serviceAccount = JSON.parse(serviceAccountJSON);
    } catch {
      throw new FCMPushError("Firebase service account JSON is invalid", 500);
    }
    if (!serviceAccount.client_email || !serviceAccount.private_key) {
      throw new FCMPushError("Firebase service account is incomplete", 500);
    }
    this.serviceAccount = serviceAccount;
    this.projectId = projectId || serviceAccount.project_id;
    if (!this.projectId) throw new FCMPushError("Firebase project ID is missing", 500);
    this.tokenUri = serviceAccount.token_uri || DEFAULT_TOKEN_URI;
    if (!this.tokenUri.startsWith("https://")) throw new FCMPushError("Firebase token URI must use HTTPS", 500);
    // Workers 里全局 fetch 以方法接收者调用会抛 "Illegal invocation"，
    // 构造时绑定到 globalThis，保证 this 正确（测试注入的假 fetch 绑定是无害 no-op）。
    this.fetchImpl = fetchImpl.bind(globalThis);
    this.clock = clock;
    this.cachedAccessToken = null;
    this.cachedAccessTokenExpiryMs = 0;
    this.signingKeyPromise = null;
  }

  async #signingKey() {
    if (!this.signingKeyPromise) {
      this.signingKeyPromise = crypto.subtle.importKey(
        "pkcs8",
        pemPrivateKey(this.serviceAccount.private_key),
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["sign"],
      );
    }
    return this.signingKeyPromise;
  }

  async #serviceAccountAssertion() {
    const issuedAt = Math.floor(this.clock() / 1000);
    const header = jwtPart({ alg: "RS256", typ: "JWT" });
    const claims = jwtPart({
      iss: this.serviceAccount.client_email,
      scope: FIREBASE_SCOPE,
      aud: this.tokenUri,
      iat: issuedAt,
      exp: issuedAt + 3600,
    });
    const signingInput = `${header}.${claims}`;
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      await this.#signingKey(),
      encoder.encode(signingInput),
    );
    return `${signingInput}.${base64URLEncode(signature)}`;
  }

  async #accessToken(forceRefresh = false) {
    if (
      !forceRefresh
      && this.cachedAccessToken
      && this.clock() < this.cachedAccessTokenExpiryMs - 60_000
    ) {
      return this.cachedAccessToken;
    }

    const response = await this.fetchImpl(this.tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: await this.#serviceAccountAssertion(),
      }),
    });
    if (!response.ok) throw new FCMPushError("Firebase OAuth token request failed", response.status);
    const value = await response.json();
    if (typeof value.access_token !== "string" || !Number.isFinite(Number(value.expires_in))) {
      throw new FCMPushError("Firebase OAuth token response is invalid");
    }
    this.cachedAccessToken = value.access_token;
    this.cachedAccessTokenExpiryMs = this.clock() + Number(value.expires_in) * 1000;
    return this.cachedAccessToken;
  }

  #request(device, delivery) {
    let payload;
    if (delivery.kind === "state") payload = delivery.envelope;
    else if (delivery.kind === "transport") payload = delivery.event;
    else throw new FCMPushError("Unsupported push delivery kind", 500);

    const data = {
      version: "1",
      kind: delivery.kind,
      payload: JSON.stringify(payload),
    };
    if (encoder.encode(JSON.stringify(data)).length > 3900) {
      throw new FCMPushError("Encrypted Discipline payload exceeds the FCM data limit", 413);
    }
    return {
      message: {
        fid: device.fcmToken,
        data,
        android: {
          priority: "HIGH",
          ttl: "600s",
          collapse_key: "discipline-status",
        },
      },
    };
  }

  async #sendRequest(device, delivery, forceRefresh) {
    const response = await this.fetchImpl(
      `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.projectId)}/messages:send`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${await this.#accessToken(forceRefresh)}`,
          "content-type": "application/json; charset=utf-8",
        },
        body: JSON.stringify(this.#request(device, delivery)),
      },
    );
    return response;
  }

  async send(device, delivery) {
    let response = await this.#sendRequest(device, delivery, false);
    if (response.status === 401) response = await this.#sendRequest(device, delivery, true);
    if (!response.ok) throw new FCMPushError("FCM message delivery failed", response.status);
    const value = await response.json();
    if (typeof value.name !== "string") throw new FCMPushError("FCM response is invalid");
    return { name: value.name };
  }
}

export const fcmConstants = Object.freeze({ scope: FIREBASE_SCOPE });
