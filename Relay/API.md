# Discipline relay HTTP API v1

All request and response bodies are UTF-8 JSON. Bodies are limited to 64 KiB.
Authenticated routes use an unpadded base64url bearer token containing at least
32 random bytes. The relay stores only SHA-256 token digests.

## Routes

| Method | Route | Authentication | Body / result |
|---|---|---|---|
| `GET` | `/v1/health` | none | protocol version and process health |
| `POST` | `/v1/pairings` | host token | pairing offer → registered offer |
| `GET` | `/v1/pairings/:pairingId?hostId=:hostId` | host token | `pending`, `expired`, `claimed`, or `removed` |
| `POST` | `/v1/pairings/:pairingId/claim` | device token | pairing claim → claimed result |
| `POST` | `/v1/envelopes` | host token | encrypted envelope → accepted sequence |
| `GET` | `/v1/devices/:deviceId/latest` | device token | 最新一条 state envelope（仅进程内内存，不落库）→ envelope JSON 或 404 |
| `PUT` | `/v1/devices/:deviceId/push-token` | device token | `{ "fcmToken": "…" }` → updated route |
| `DELETE` | `/v1/hosts/:hostId/devices/:deviceId` | host token | remove access from the Mac |
| `DELETE` | `/v1/devices/:deviceId` | device token | unpair from Android |

Pairing offers and claims, state envelopes, and offline transport events use the
schemas under `../Protocol`. Access tokens are HTTP transport credentials and
are never placed in a QR protocol object or encrypted state object.

## Sequence conflict

The relay may consume a sequence number when it sends an offline event. A stale
Mac envelope receives HTTP `409`:

```json
{
  "error": {
    "code": "sequence_replay",
    "message": "Sequence was already used",
    "details": { "minimumSequence": 45 }
  }
}
```

The Mac must encrypt the same current state again with a fresh nonce and the
returned minimum sequence.

## FCM delivery

The Worker sends an FCM HTTP v1 data message. Every data value is a string:

```json
{
  "version": "1",
  "kind": "state",
  "payload": "{...encrypted envelope JSON...}"
}
```

`kind` is `state` or `transport`. Delivery is high priority, expires after 600
seconds, and uses the `discipline-status` collapse key. The Android receiver is
responsible for decrypting state, verifying transport signatures, enforcing
sequence ordering, and rendering the visible notification immediately.
