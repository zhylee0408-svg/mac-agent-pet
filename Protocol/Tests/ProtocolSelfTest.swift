import CryptoKit
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.message(message) }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func decodeBase64URL(_ value: String) throws -> Data {
    var encoded = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else {
        throw TestFailure.message("Invalid base64url value")
    }
    return data
}

func symmetricKeyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

func sharedSecretData(_ secret: SharedSecret) -> Data {
    secret.withUnsafeBytes { Data($0) }
}

func isTimestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
}

func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures")
        .appendingPathComponent(name)
}

func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let data = try Data(contentsOf: fixtureURL(name))
    return try JSONDecoder().decode(type, from: data)
}

struct SourceSnapshot: Codable {
    let id: String
    let label: String
    let online: Bool
    let status: String?
}

struct StateMessage: Codable {
    let version: Int
    let type: String
    let sequence: UInt64
    let source: String
    let status: String
    let sources: [SourceSnapshot]
    let updatedAt: String
}

struct PairingOffer: Codable {
    let version: Int
    let type: String
    let relayUrl: String
    let pairingId: String
    let oneTimeToken: String
    let hostId: String
    let hostName: String
    let hostPublicKey: String
    let kdfSalt: String
    let relaySigningPublicKey: String
    let expiresAt: String
}

struct PairingClaim: Codable {
    let version: Int
    let type: String
    let pairingId: String
    let oneTimeToken: String
    let deviceId: String
    let deviceName: String
    let devicePublicKey: String
    let fcmToken: String
}

struct PairingClaimed: Codable {
    let version: Int
    let type: String
    let pairingId: String
    let deviceId: String
    let deviceName: String
    let devicePublicKey: String
    let keyId: String
    let claimedAt: String
}

struct EncryptedEnvelope: Codable {
    let version: Int
    let algorithm: String
    let hostId: String
    let deviceId: String
    let keyId: String
    let sequence: UInt64
    let sentAt: String
    let nonce: String
    let ciphertext: String
}

struct TransportEvent: Codable {
    let version: Int
    let type: String
    let event: String
    let hostId: String
    let deviceId: String
    let sequence: UInt64
    let observedAt: String
    let timeoutSeconds: Int
    let reason: String
    let signature: String
}

struct CryptoVector: Codable {
    let version: Int
    let hostPrivateKey: String
    let hostPublicKey: String
    let devicePrivateKey: String
    let devicePublicKey: String
    let sharedSecret: String
    let kdfSalt: String
    let sharedInfo: String
    let derivedKey: String
    let hostId: String
    let deviceId: String
    let keyId: String
    let sequence: UInt64
    let nonce: String
    let aad: String
    let plaintext: String
    let ciphertext: String
    let relaySigningPrivateKey: String
    let relaySigningPublicKey: String
    let transportSigningInput: String
    let transportSignature: String
}

let statePlaintext = #"{"version":1,"type":"state","sequence":42,"source":"codex","status":"running","sources":[{"id":"codex","label":"Codex","online":true,"status":"running"},{"id":"dsh","label":"DSH","online":true,"status":"idle"}],"updatedAt":"2026-08-20T14:32:18+08:00"}"#

func makeCryptoVector() throws -> CryptoVector {
    let hostPrivateData = Data((1...32).map(UInt8.init))
    let devicePrivateData = Data((33...64).map(UInt8.init))
    let relayPrivateData = Data((65...96).map(UInt8.init))
    let salt = Data((97...128).map(UInt8.init))
    let nonceData = Data((160...171).map(UInt8.init))

    let hostPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateData)
    let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateData)
    let shared = try hostPrivate.sharedSecretFromKeyAgreement(with: devicePrivate.publicKey)
    let reverseShared = try devicePrivate.sharedSecretFromKeyAgreement(with: hostPrivate.publicKey)
    try require(sharedSecretData(shared) == sharedSecretData(reverseShared), "X25519 agreement is asymmetric")

    let sharedInfo = "discipline-mobile-state-v1"
    let derived = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: Data(sharedInfo.utf8),
        outputByteCount: 32
    )

    let hostId = "host_demo"
    let deviceId = "device_demo"
    let keyId = "key_demo"
    let sequence: UInt64 = 42
    let aad = "discipline:v1:\(hostId):\(deviceId):\(sequence):\(keyId)"
    let nonce = try AES.GCM.Nonce(data: nonceData)
    let sealed = try AES.GCM.seal(
        Data(statePlaintext.utf8),
        using: derived,
        nonce: nonce,
        authenticating: Data(aad.utf8)
    )
    let ciphertextAndTag = sealed.ciphertext + sealed.tag

    let relayPrivate = try Curve25519.Signing.PrivateKey(rawRepresentation: relayPrivateData)
    let transportInput = "discipline:v1:transport:host_demo:device_demo:43:offline:2026-08-20T14:42:18+08:00:600"
    let signature = try relayPrivate.signature(for: Data(transportInput.utf8))

    return CryptoVector(
        version: 1,
        hostPrivateKey: base64URL(hostPrivateData),
        hostPublicKey: base64URL(hostPrivate.publicKey.rawRepresentation),
        devicePrivateKey: base64URL(devicePrivateData),
        devicePublicKey: base64URL(devicePrivate.publicKey.rawRepresentation),
        sharedSecret: base64URL(sharedSecretData(shared)),
        kdfSalt: base64URL(salt),
        sharedInfo: sharedInfo,
        derivedKey: base64URL(symmetricKeyData(derived)),
        hostId: hostId,
        deviceId: deviceId,
        keyId: keyId,
        sequence: sequence,
        nonce: base64URL(nonceData),
        aad: aad,
        plaintext: statePlaintext,
        ciphertext: base64URL(ciphertextAndTag),
        relaySigningPrivateKey: base64URL(relayPrivateData),
        relaySigningPublicKey: base64URL(relayPrivate.publicKey.rawRepresentation),
        transportSigningInput: transportInput,
        transportSignature: base64URL(signature)
    )
}

func validateState(_ message: StateMessage, fixture: String) throws {
    let states = Set(["idle", "running", "needs_input", "ready", "blocked"])
    try require(message.version == 1, "\(fixture): version must be 1")
    try require(message.type == "state", "\(fixture): type must be state")
    try require(states.contains(message.status), "\(fixture): invalid effective status")
    try require(isTimestamp(message.updatedAt), "\(fixture): invalid updatedAt")
    try require(!message.sources.isEmpty, "\(fixture): sources must not be empty")
    try require(Set(message.sources.map(\.id)).count == message.sources.count, "\(fixture): duplicate source id")

    for source in message.sources {
        try require(!source.id.isEmpty && !source.label.isEmpty, "\(fixture): blank source identity")
        if source.online {
            try require(source.status.map(states.contains) == true, "\(fixture): online source needs a valid status")
        } else {
            try require(source.status == nil, "\(fixture): offline source status must be null")
        }
    }

    if message.source == "none" {
        try require(message.status == "idle", "\(fixture): source none is valid only for idle")
    } else {
        guard let selected = message.sources.first(where: { $0.id == message.source }) else {
            throw TestFailure.message("\(fixture): selected source is missing")
        }
        try require(selected.online, "\(fixture): selected source must be online")
        try require(selected.status == message.status, "\(fixture): selected source status mismatch")
    }
}

func validateFixtures() throws {
    let stateFixtures = [
        "state-running.json",
        "state-needs-input.json",
        "state-blocked.json",
        "state-ready.json",
        "state-idle-none.json",
        "state-source-offline.json"
    ]
    for name in stateFixtures {
        try validateState(try load(name, as: StateMessage.self), fixture: name)
    }

    let offer = try load("pairing-offer.json", as: PairingOffer.self)
    try require(offer.version == 1 && offer.type == "pairing_offer", "Invalid pairing offer header")
    try require(URL(string: offer.relayUrl)?.scheme == "https", "Pairing relay must use HTTPS")
    try require(try decodeBase64URL(offer.hostPublicKey).count == 32, "Host public key must be 32 bytes")
    try require(try decodeBase64URL(offer.kdfSalt).count == 32, "KDF salt must be 32 bytes")
    try require(try decodeBase64URL(offer.relaySigningPublicKey).count == 32, "Relay signing key must be 32 bytes")
    try require(isTimestamp(offer.expiresAt), "Invalid pairing expiry")

    let claim = try load("pairing-claim.json", as: PairingClaim.self)
    try require(claim.version == 1 && claim.type == "pairing_claim", "Invalid pairing claim header")
    try require(claim.pairingId == offer.pairingId, "Pairing IDs do not match")
    try require(claim.oneTimeToken == offer.oneTimeToken, "One-time tokens do not match")
    try require(try decodeBase64URL(claim.devicePublicKey).count == 32, "Device public key must be 32 bytes")

    let claimed = try load("pairing-claimed.json", as: PairingClaimed.self)
    try require(claimed.version == 1 && claimed.type == "pairing_claimed", "Invalid claimed message header")
    try require(claimed.pairingId == claim.pairingId, "Claimed pairing ID mismatch")
    try require(claimed.deviceId == claim.deviceId, "Claimed device ID mismatch")
    try require(claimed.devicePublicKey == claim.devicePublicKey, "Claimed device public key mismatch")
    try require(isTimestamp(claimed.claimedAt), "Invalid claimedAt")

    let envelope = try load("encrypted-envelope.json", as: EncryptedEnvelope.self)
    try require(envelope.version == 1, "Envelope version must be 1")
    try require(envelope.algorithm == "X25519-HKDF-SHA256-A256GCM", "Unexpected envelope algorithm")
    try require(try decodeBase64URL(envelope.nonce).count == 12, "AES-GCM nonce must be 12 bytes")
    try require(try decodeBase64URL(envelope.ciphertext).count > 16, "Ciphertext must include a 16-byte tag")
    try require(isTimestamp(envelope.sentAt), "Invalid envelope sentAt")

    let transport = try load("transport-offline.json", as: TransportEvent.self)
    try require(transport.version == 1 && transport.type == "transport", "Invalid transport header")
    try require(transport.event == "offline" && transport.reason == "heartbeat_timeout", "Invalid transport event")
    try require(transport.timeoutSeconds == 600, "Offline timeout must be 600 seconds")
    try require(try decodeBase64URL(transport.signature).count == 64, "Ed25519 signature must be 64 bytes")
    try require(isTimestamp(transport.observedAt), "Invalid transport observedAt")
}

func validateCryptoVector() throws {
    let expected = try load("crypto-vector-v1.json", as: CryptoVector.self)
    let generated = try makeCryptoVector()
    try require(expected.version == 1, "Crypto vector version must be 1")
    try require(expected.hostPublicKey == generated.hostPublicKey, "Host public key vector mismatch")
    try require(expected.devicePublicKey == generated.devicePublicKey, "Device public key vector mismatch")
    try require(expected.sharedSecret == generated.sharedSecret, "Shared secret vector mismatch")
    try require(expected.derivedKey == generated.derivedKey, "HKDF vector mismatch")
    try require(expected.ciphertext == generated.ciphertext, "AES-GCM vector mismatch")
    try require(expected.relaySigningPublicKey == generated.relaySigningPublicKey, "Relay public key vector mismatch")

    // CryptoKit deliberately randomizes Ed25519 signatures, so two valid
    // signatures over the same input need not have identical bytes. Verify the
    // fixed interoperability vector and the newly generated signature instead.
    let generatedRelayPublic = try Curve25519.Signing.PublicKey(
        rawRepresentation: decodeBase64URL(generated.relaySigningPublicKey)
    )
    try require(
        generatedRelayPublic.isValidSignature(
            try decodeBase64URL(generated.transportSignature),
            for: Data(generated.transportSigningInput.utf8)
        ),
        "Generated Ed25519 signature verification failed"
    )

    let key = SymmetricKey(data: try decodeBase64URL(expected.derivedKey))
    let nonce = try AES.GCM.Nonce(data: decodeBase64URL(expected.nonce))
    let encrypted = try decodeBase64URL(expected.ciphertext)
    let split = encrypted.count - 16
    let box = try AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: encrypted.prefix(split),
        tag: encrypted.suffix(16)
    )
    let opened = try AES.GCM.open(box, using: key, authenticating: Data(expected.aad.utf8))
    try require(opened == Data(expected.plaintext.utf8), "AES-GCM authenticated decryption failed")

    let relayPublic = try Curve25519.Signing.PublicKey(
        rawRepresentation: decodeBase64URL(expected.relaySigningPublicKey)
    )
    try require(
        relayPublic.isValidSignature(
            try decodeBase64URL(expected.transportSignature),
            for: Data(expected.transportSigningInput.utf8)
        ),
        "Ed25519 signature verification failed"
    )

    let envelope = try load("encrypted-envelope.json", as: EncryptedEnvelope.self)
    try require(envelope.hostId == expected.hostId, "Envelope host ID differs from vector")
    try require(envelope.deviceId == expected.deviceId, "Envelope device ID differs from vector")
    try require(envelope.keyId == expected.keyId, "Envelope key ID differs from vector")
    try require(envelope.sequence == expected.sequence, "Envelope sequence differs from vector")
    try require(envelope.nonce == expected.nonce, "Envelope nonce differs from vector")
    try require(envelope.ciphertext == expected.ciphertext, "Envelope ciphertext differs from vector")

    let transport = try load("transport-offline.json", as: TransportEvent.self)
    try require(transport.signature == expected.transportSignature, "Transport fixture signature differs from vector")
    try require(expected.transportSigningInput.contains(":\(transport.sequence):offline:\(transport.observedAt):\(transport.timeoutSeconds)"), "Transport signing input differs from fixture")
}

do {
    if CommandLine.arguments.contains("--generate-vector") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(makeCryptoVector())
        print(String(decoding: data, as: UTF8.self))
    } else {
        try validateFixtures()
        try validateCryptoVector()
        print("Discipline mobile protocol v1 self-test passed")
    }
} catch {
    FileHandle.standardError.write(Data("Protocol self-test failed: \(error)\n".utf8))
    exit(1)
}
