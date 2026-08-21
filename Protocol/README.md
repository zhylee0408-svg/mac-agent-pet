# Discipline Mobile Protocol v1

This directory is the cross-platform contract shared by Discipline for macOS,
the Cloudflare relay, and Discipline for Android. The relay routes encrypted
state messages and never receives task text, terminal output, file contents, or
conversation content.

## Semantic state

`state-v1.schema.json` carries the state already selected by the macOS
`SourceArbiter`, plus a small per-source snapshot for the expanded Android
notification.

The task-state values are fixed for v1:

| Wire value | Notification lamp | Compact status icon |
|---|---|---|
| `blocked` | red | cross |
| `needs_input` | yellow | exclamation mark |
| `running` | blue | filled circle |
| `ready` | green | check mark |
| `idle` | gray | hollow circle |

`offline` is deliberately not a task state. It is a transport event generated
after ten minutes without a Mac heartbeat. Android renders it with all five
lamps off and a broken-ring status icon. A source can independently be offline;
in that case its `online` field is `false` and its `status` is `null`.

The compact notification is rendered as:

```text
Discipline
Source: Codex    Status: Running
Updated: 14:32:18    2026-08-20
```

The expanded notification adds one line per source, in the order received:

```text
Codex: Running
DSH: Idle
```

`updatedAt` changes only when user-visible state data changes. Heartbeats do not
change it. Android formats it in the phone's local timezone.

## Ordering and notification behavior

`sequence` is monotonically increasing for each host/device pairing. Android
must ignore an envelope or transport event whose sequence is not greater than
the last accepted sequence.

Android derives alert behavior locally:

- `running`, `idle`, and a source-only switch with unchanged status are silent.
- `ready`, `needs_input`, and `blocked` play one sound and never vibrate.
- the ten-minute `offline` transition is silent.
- offline to online `idle` or `running` is silent.
- offline to `ready`, `needs_input`, or `blocked` plays one sound.

## Pairing

`pairing-v1.schema.json` defines the copyable/QR offer, the Android claim, and
the claim result returned to the Mac. The user-facing text has the form
`discipline://pair?...`; Android accepts it through one input field and a
Connect button. The code contains the relay address, host public material, and
a five-minute one-time token. It never contains the Android device ID, a device
private key, a device access token, or the derived long-term state key.

The phone creates its own device ID, X25519 key pair, and relay access token
locally before claiming the offer. This keeps the simple copy/paste flow while
preventing the Mac or relay from choosing the phone's long-term identity.

The Mac and phone each create an X25519 key pair. They derive a 256-bit state
key using HKDF-SHA256:

```text
salt       = pairing offer kdfSalt (32 random bytes)
sharedInfo = UTF-8 "discipline-mobile-state-v1"
output     = 32 bytes
```

## State encryption

`envelope-v1.schema.json` wraps the UTF-8 JSON state message. Encryption uses
AES-256-GCM with a fresh 96-bit nonce for every sequence number. The envelope's
`ciphertext` is `ciphertext || 16-byte GCM tag`, encoded as unpadded base64url.

The additional authenticated data is the UTF-8 encoding of:

```text
discipline:v1:<hostId>:<deviceId>:<sequence>:<keyId>
```

All binary fields use RFC 4648 base64url without `=` padding.

## Offline events

The relay retains only pairing/routing metadata and `last_heartbeat`. A cron
check emits `transport-v1.schema.json` once after 600 seconds without a
heartbeat. The event contains no task state and is signed with Ed25519 over:

```text
discipline:v1:transport:<hostId>:<deviceId>:<sequence>:offline:<observedAt>:600
```

Android verifies the signature using `relaySigningPublicKey` from the pairing
offer.

## Self-test

Run:

```bash
./Protocol/test.sh
```

The test decodes every fixture, checks cross-field invariants that JSON Schema
cannot express conveniently, verifies the fixed X25519/HKDF/AES-GCM vector, and
checks authenticated decryption.

`fixtures/crypto-vector-v1.json` intentionally contains deterministic test
private keys so other implementations can reproduce the same results. They are
public test material and must never be used by a deployed Mac, relay, or phone.
