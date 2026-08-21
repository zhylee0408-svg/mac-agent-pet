# Discipline thin relay core

This directory contains the environment-independent core plus the Cloudflare
Worker, D1, and FCM HTTP v1 adapters. The production relay is deployed at
`https://discipline-relay.discipline-zhylee.workers.dev`; the health endpoint is
`/v1/health`. The integration test replaces Google endpoints with an in-process
fake and makes no network requests.

## Responsibilities

- register a five-minute pairing offer and retain only a hash of its one-time
  token;
- allow exactly one Android device for a host in protocol v1;
- authenticate Mac and phone control operations with separate 256-bit access
  tokens, retaining hashes rather than the tokens;
- let an authenticated phone replace a rotated Firebase Installation ID (FID);
- forward the encrypted state envelope without decrypting it;
- treat each successfully forwarded envelope as the Mac heartbeat;
- emit one signed `offline` transport event at 600 seconds without a heartbeat;
- support removal by the Mac and unpairing by the phone.

The relay database stores host/device routing metadata, FCM routing identifiers,
public keys, access-token hashes, the last accepted sequence, and the last
heartbeat time. It does **not** store an encrypted envelope, nonce, semantic
state, source, notification text, task text, terminal output, file content, or
conversation content.

Delivery reservations expire after 60 seconds. This allows another request to
recover automatically if a Worker stops between reserving a sequence and
committing a push, without persisting the encrypted payload as an outbox.

The push object exists only while it is passed to the future FCM adapter. The
test push collector is intentionally separate from `MemoryRelayStore` so the
privacy assertion can inspect everything that represents persistent storage.

## Sequence recovery after offline

The relay consumes the next sequence number when it creates an offline event.
If a returning Mac tries that number, `publishEnvelope` rejects it with
`sequence_replay` and `details.minimumSequence`. The Mac must rebuild the
AES-GCM envelope with that minimum sequence because the sequence is part of the
authenticated data. This keeps a single total order on Android without letting
the relay rewrite encrypted state.

## Cloudflare boundary

`migrations/0001_initial.sql` freezes the D1 storage boundary.
`src/d1-store.mjs` uses prepared statements and transactional D1 batches.
`src/worker.mjs` exposes the routes listed in `API.md` and runs the offline scan
from a scheduled handler. `src/fcm-push.mjs` creates a short-lived OAuth 2.0
token from the Firebase service account secret and calls FCM HTTP v1 using the
dedicated `message.fid` target field.

`wrangler.jsonc` contains the production public URL, relay signing public key,
Firebase project ID, and D1 binding. The production D1 database is
`discipline-relay` (`61cf9495-7511-446b-b536-6af7d8744f7c`) in APAC. These two
Worker secrets are configured in Cloudflare and are never committed:

- `RELAY_SIGNING_PRIVATE_KEY_PKCS8`
- `FIREBASE_SERVICE_ACCOUNT_JSON`

Observability persistence is disabled in the template to avoid retaining
request logs by default. The scheduled sweep logs counts only, never IDs or
payloads.

The Firebase service account uses one uploaded RSA public certificate. Its
private key exists only in the Cloudflare secret; temporary local PEM and JSON
files are removed after deployment. Preview URLs are disabled, leaving only the
production `workers.dev` route.

## Verify

From the repository root:

```bash
./Relay/test.sh
```

To verify the deployed boundary without exposing credentials:

```bash
curl --fail https://discipline-relay.discipline-zhylee.workers.dev/v1/health
cd Relay && npx wrangler secret list
```

The first line tests the relay core. The second runs an HTTP → D1 → OAuth JWT →
FCM integration flow against an in-memory SQLite database and fake Google
endpoint. It verifies the Ed25519 signature created by Swift with JavaScript Web
Crypto and verifies the locally generated Google OAuth JWT with an independent
RSA public key.
