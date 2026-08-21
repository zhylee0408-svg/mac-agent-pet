const encoder = new TextEncoder();

export function base64URLDecode(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new TypeError("Invalid unpadded base64url value");
  }
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function base64URLEncode(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

export async function tokenDigest(scope, identity, token) {
  const input = encoder.encode(`discipline:v1:token:${scope}:${identity}:${token}`);
  return base64URLEncode(await crypto.subtle.digest("SHA-256", input));
}

export function constantTimeEqual(left, right) {
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

export function transportSigningInput(event) {
  return [
    "discipline",
    "v1",
    "transport",
    event.hostId,
    event.deviceId,
    String(event.sequence),
    event.event,
    event.observedAt,
    String(event.timeoutSeconds),
  ].join(":");
}

export async function createEd25519Signer(privateKeyPKCS8) {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    base64URLDecode(privateKeyPKCS8),
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  return async (input) => base64URLEncode(
    await crypto.subtle.sign("Ed25519", key, encoder.encode(input)),
  );
}

export async function verifyEd25519(publicKey, input, signature) {
  const key = await crypto.subtle.importKey(
    "raw",
    base64URLDecode(publicKey),
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "Ed25519",
    key,
    base64URLDecode(signature),
    encoder.encode(input),
  );
}
