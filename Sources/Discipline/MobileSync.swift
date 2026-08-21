import CryptoKit
import Foundation
import Security

private let mobileProtocolVersion = 1
private let mobileAlgorithm = "X25519-HKDF-SHA256-A256GCM"
private let mobileSharedInfo = Data("discipline-mobile-state-v1".utf8)

func mobileBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func mobileDecodeBase64URL(_ value: String) -> Data? {
    var encoded = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    return Data(base64Encoded: encoded)
}

private func mobileRandomBytes(count: Int) -> Data? {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        return nil
    }
    return Data(bytes)
}

private func mobileIdentifier(prefix: String) -> String {
    prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
}

private let mobileISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

extension PetState {
    var mobileWireValue: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .needs: return "needs_input"
        case .ready: return "ready"
        case .blocked: return "blocked"
        }
    }
}

struct MobileSourceSnapshot: Codable, Equatable {
    let id: String
    let label: String
    let online: Bool
    let status: String?
}

struct MobileProjectedState: Equatable {
    let source: String
    let status: String
    let sources: [MobileSourceSnapshot]

    static func make(
        driver: LiveSourceCandidate?,
        candidates: [LiveSourceCandidate]
    ) -> MobileProjectedState {
        let bySource = Dictionary(uniqueKeysWithValues: candidates.map { ($0.source, $0) })
        let sources = [
            (id: "codex", label: "Codex"),
            (id: "dsh", label: "DSH")
        ].map { definition -> MobileSourceSnapshot in
            guard let candidate = bySource[definition.label] else {
                return MobileSourceSnapshot(
                    id: definition.id,
                    label: definition.label,
                    online: false,
                    status: nil
                )
            }
            return MobileSourceSnapshot(
                id: definition.id,
                label: definition.label,
                online: true,
                status: candidate.state.mobileWireValue
            )
        }

        guard let driver else {
            return MobileProjectedState(source: "none", status: "idle", sources: sources)
        }
        return MobileProjectedState(
            source: driver.bridgePrefix,
            status: driver.state.mobileWireValue,
            sources: sources
        )
    }
}

struct MobileStateMessage: Codable, Equatable {
    let version: Int
    let type: String
    let sequence: UInt64
    let source: String
    let status: String
    let sources: [MobileSourceSnapshot]
    let updatedAt: String
}

struct MobileEncryptedEnvelope: Codable, Equatable {
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

enum MobileEnvelopeCodec {
    static func seal(
        projected: MobileProjectedState,
        updatedAt: Date,
        sequence: UInt64,
        hostId: String,
        deviceId: String,
        keyId: String,
        stateKey: Data,
        sentAt: Date = Date()
    ) throws -> MobileEncryptedEnvelope {
        let message = MobileStateMessage(
            version: mobileProtocolVersion,
            type: "state",
            sequence: sequence,
            source: projected.source,
            status: projected.status,
            sources: projected.sources,
            updatedAt: mobileISO8601.string(from: updatedAt)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(message)
        let aad = Data("discipline:v1:\(hostId):\(deviceId):\(sequence):\(keyId)".utf8)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: stateKey),
            authenticating: aad
        )
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return MobileEncryptedEnvelope(
            version: mobileProtocolVersion,
            algorithm: mobileAlgorithm,
            hostId: hostId,
            deviceId: deviceId,
            keyId: keyId,
            sequence: sequence,
            sentAt: mobileISO8601.string(from: sentAt),
            nonce: mobileBase64URL(nonce),
            ciphertext: mobileBase64URL(sealed.ciphertext + sealed.tag)
        )
    }
}

struct MobilePairingOffer: Codable, Equatable {
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

struct MobilePairingClaimed: Codable, Equatable {
    let version: Int
    let type: String
    let pairingId: String
    let deviceId: String
    let deviceName: String
    let devicePublicKey: String
    let keyId: String
    let claimedAt: String
}

enum MobilePairingCode {
    static func encode(_ offer: MobilePairingOffer) -> String? {
        var components = URLComponents()
        components.scheme = "discipline"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(offer.version)),
            URLQueryItem(name: "relay", value: offer.relayUrl),
            URLQueryItem(name: "pairing", value: offer.pairingId),
            URLQueryItem(name: "token", value: offer.oneTimeToken),
            URLQueryItem(name: "host", value: offer.hostId),
            URLQueryItem(name: "name", value: offer.hostName),
            URLQueryItem(name: "host_key", value: offer.hostPublicKey),
            URLQueryItem(name: "salt", value: offer.kdfSalt),
            URLQueryItem(name: "relay_key", value: offer.relaySigningPublicKey),
            URLQueryItem(name: "expires", value: offer.expiresAt)
        ]
        return components.string
    }

    static func decode(_ value: String) -> MobilePairingOffer? {
        guard
            let components = URLComponents(string: value),
            components.scheme == "discipline",
            components.host == "pair"
        else { return nil }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item in item.value.map { (item.name, $0) }
        })
        guard
            values["v"] == "1",
            let relay = values["relay"], URL(string: relay)?.scheme == "https",
            let pairing = values["pairing"], !pairing.isEmpty,
            let token = values["token"], (mobileDecodeBase64URL(token)?.count ?? 0) >= 32,
            let host = values["host"], !host.isEmpty,
            let name = values["name"], !name.isEmpty,
            let hostKey = values["host_key"], mobileDecodeBase64URL(hostKey)?.count == 32,
            let salt = values["salt"], mobileDecodeBase64URL(salt)?.count == 32,
            let relayKey = values["relay_key"], mobileDecodeBase64URL(relayKey)?.count == 32,
            let expires = values["expires"], mobileISO8601.date(from: expires) != nil
        else { return nil }
        return MobilePairingOffer(
            version: 1,
            type: "pairing_offer",
            relayUrl: relay,
            pairingId: pairing,
            oneTimeToken: token,
            hostId: host,
            hostName: name,
            hostPublicKey: hostKey,
            kdfSalt: salt,
            relaySigningPublicKey: relayKey,
            expiresAt: expires
        )
    }
}

private struct MobileHostIdentity: Codable {
    let hostId: String
    let hostAccessToken: String
    let hostPrivateKey: String
}

private struct MobilePairedDevice: Codable {
    let relayURL: String
    let relaySigningPublicKey: String
    let deviceId: String
    let deviceName: String
    let keyId: String
    let stateKey: String
    var nextSequence: UInt64
}

private struct MobileSecureState: Codable {
    var host: MobileHostIdentity
    var device: MobilePairedDevice?
}

private final class MobileKeychainStore {
    private let service = "com.zhylee.discipline.mobile-sync"
    private let account = "primary"

    func load() -> MobileSecureState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(MobileSecureState.self, from: data)
    }

    func save(_ state: MobileSecureState) throws {
        let data = try JSONEncoder().encode(state)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MobileSyncError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw MobileSyncError.keychain(status)
        }
    }
}

private struct MobilePairingStatusResponse: Decodable {
    let status: String
    let expiresAt: String?
    let deviceId: String?
    let claimed: MobilePairingClaimed?
}

private struct MobilePublishResponse: Decodable {
    let accepted: Bool
    let sequence: UInt64
}

private struct MobileRelayErrorBody: Decodable {
    struct Body: Decodable {
        struct Details: Decodable { let minimumSequence: UInt64? }
        let code: String
        let message: String
        let details: Details?
    }
    let error: Body
}

enum MobileSyncError: Error, LocalizedError {
    case notConfigured
    case invalidConfiguration
    case randomGeneration
    case alreadyPaired
    case keychain(OSStatus)
    case invalidResponse
    case relay(Int, String, String, UInt64?)
    case pairingExpired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Mobile relay is not configured yet"
        case .invalidConfiguration: return "Mobile relay configuration is invalid"
        case .randomGeneration: return "Secure random generation failed"
        case .alreadyPaired: return "Revoke the current phone before creating another pairing code"
        case .keychain(let status): return "Keychain operation failed (\(status))"
        case .invalidResponse: return "The relay returned an invalid response"
        case .relay(_, _, let message, _): return message
        case .pairingExpired: return "The pairing code expired"
        }
    }
}

private final class MobileRelayClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func register(offer: MobilePairingOffer, token: String) async throws {
        var request = try request(base: offer.relayUrl, path: "v1/pairings", method: "POST", token: token)
        request.httpBody = try encoder.encode(offer)
        let (_, response) = try await session.data(for: request)
        try validate(response: response, data: nil, expected: 201)
    }

    func pairingStatus(
        relayURL: String,
        pairingId: String,
        hostId: String,
        token: String
    ) async throws -> MobilePairingStatusResponse {
        var components = URLComponents(
            url: try endpoint(base: relayURL, path: "v1/pairings/\(pairingId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "hostId", value: hostId)]
        guard let url = components?.url else { throw MobileSyncError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, expected: 200)
        return try decoder.decode(MobilePairingStatusResponse.self, from: data)
    }

    func publish(
        envelope: MobileEncryptedEnvelope,
        relayURL: String,
        token: String
    ) async throws -> MobilePublishResponse {
        var request = try request(base: relayURL, path: "v1/envelopes", method: "POST", token: token)
        request.httpBody = try encoder.encode(envelope)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, expected: 202)
        return try decoder.decode(MobilePublishResponse.self, from: data)
    }

    func revoke(relayURL: String, hostId: String, deviceId: String, token: String) async throws {
        let path = "v1/hosts/\(hostId)/devices/\(deviceId)"
        let request = try request(base: relayURL, path: path, method: "DELETE", token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, expected: 200)
    }

    private func request(base: String, path: String, method: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(base: base, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private func endpoint(base: String, path: String) throws -> URL {
        guard let baseURL = URL(string: base), baseURL.scheme == "https" else {
            throw MobileSyncError.invalidConfiguration
        }
        return baseURL.appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data?, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw MobileSyncError.invalidResponse }
        guard http.statusCode == expected else {
            if let data, let body = try? decoder.decode(MobileRelayErrorBody.self, from: data) {
                throw MobileSyncError.relay(
                    http.statusCode,
                    body.error.code,
                    body.error.message,
                    body.error.details?.minimumSequence
                )
            }
            throw MobileSyncError.relay(http.statusCode, "http_error", "Relay HTTP \(http.statusCode)", nil)
        }
    }
}

@MainActor
final class MobileSyncCoordinator {
    typealias StatusHandler = (String) -> Void

    private let defaults: UserDefaults
    private let keychain = MobileKeychainStore()
    private let client: MobileRelayClient
    private let statusHandler: StatusHandler
    private var secureState: MobileSecureState?
    private var projectedState: MobileProjectedState?
    private var updatedAt = Date()
    private var heartbeatTimer: Timer?
    private var pairingTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var publishRequested = false

    init(
        defaults: UserDefaults = .standard,
        statusHandler: @escaping StatusHandler
    ) {
        self.defaults = defaults
        self.client = MobileRelayClient()
        self.statusHandler = statusHandler
    }

    var isPaired: Bool { secureState?.device != nil }

    func start() {
        secureState = keychain.load()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestPublish(reason: "heartbeat") }
        }
        updateStatus()
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pairingTask?.cancel()
        publishTask?.cancel()
    }

    func update(_ state: MobileProjectedState) {
        if projectedState != state {
            projectedState = state
            updatedAt = Date()
            requestPublish(reason: "state changed")
        }
    }

    func createPairingCode() async throws -> String {
        guard let relayURL = defaults.string(forKey: "mobileRelayURL"),
              let relaySigningKey = defaults.string(forKey: "mobileRelaySigningPublicKey")
        else { throw MobileSyncError.notConfigured }
        guard URL(string: relayURL)?.scheme == "https",
              mobileDecodeBase64URL(relaySigningKey)?.count == 32
        else { throw MobileSyncError.invalidConfiguration }

        let state = try secureState ?? makeSecureState()
        guard state.device == nil else { throw MobileSyncError.alreadyPaired }
        guard
            let privateKeyData = mobileDecodeBase64URL(state.host.hostPrivateKey),
            let oneTimeTokenData = mobileRandomBytes(count: 32),
            let salt = mobileRandomBytes(count: 32)
        else { throw MobileSyncError.randomGeneration }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let offer = MobilePairingOffer(
            version: mobileProtocolVersion,
            type: "pairing_offer",
            relayUrl: relayURL,
            pairingId: mobileIdentifier(prefix: "pair_"),
            oneTimeToken: mobileBase64URL(oneTimeTokenData),
            hostId: state.host.hostId,
            hostName: String((Host.current().localizedName ?? "Mac").prefix(80)),
            hostPublicKey: mobileBase64URL(privateKey.publicKey.rawRepresentation),
            kdfSalt: mobileBase64URL(salt),
            relaySigningPublicKey: relaySigningKey,
            expiresAt: mobileISO8601.string(from: Date().addingTimeInterval(300))
        )
        try keychain.save(state)
        secureState = state
        try await client.register(offer: offer, token: state.host.hostAccessToken)
        guard let code = MobilePairingCode.encode(offer) else {
            throw MobileSyncError.invalidConfiguration
        }
        beginPairingPoll(offer: offer)
        statusHandler("Mobile: Waiting for phone…")
        return code
    }

    func revoke() async throws {
        guard var state = secureState, let device = state.device else { return }
        try await client.revoke(
            relayURL: device.relayURL,
            hostId: state.host.hostId,
            deviceId: device.deviceId,
            token: state.host.hostAccessToken
        )
        state.device = nil
        try keychain.save(state)
        secureState = state
        updateStatus()
    }

    private func makeSecureState() throws -> MobileSecureState {
        guard let token = mobileRandomBytes(count: 32) else { throw MobileSyncError.randomGeneration }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return MobileSecureState(
            host: MobileHostIdentity(
                hostId: mobileIdentifier(prefix: "mac_"),
                hostAccessToken: mobileBase64URL(token),
                hostPrivateKey: mobileBase64URL(privateKey.rawRepresentation)
            ),
            device: nil
        )
    }

    private func beginPairingPoll(offer: MobilePairingOffer) {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    guard let state = self.secureState else { return }
                    let status = try await self.client.pairingStatus(
                        relayURL: offer.relayUrl,
                        pairingId: offer.pairingId,
                        hostId: offer.hostId,
                        token: state.host.hostAccessToken
                    )
                    switch status.status {
                    case "claimed":
                        guard let claimed = status.claimed else { throw MobileSyncError.invalidResponse }
                        try self.finishPairing(offer: offer, claimed: claimed)
                        return
                    case "expired", "removed":
                        throw MobileSyncError.pairingExpired
                    default:
                        if Date() > (mobileISO8601.date(from: offer.expiresAt) ?? .distantPast) {
                            throw MobileSyncError.pairingExpired
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.statusHandler("Mobile: \(error.localizedDescription)")
            }
        }
    }

    private func finishPairing(offer: MobilePairingOffer, claimed: MobilePairingClaimed) throws {
        guard var state = secureState,
              claimed.pairingId == offer.pairingId,
              let privateData = mobileDecodeBase64URL(state.host.hostPrivateKey),
              let devicePublicData = mobileDecodeBase64URL(claimed.devicePublicKey),
              let salt = mobileDecodeBase64URL(offer.kdfSalt)
        else { throw MobileSyncError.invalidResponse }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateData)
        let devicePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: devicePublic)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: mobileSharedInfo,
            outputByteCount: 32
        )
        let keyData = key.withUnsafeBytes { Data($0) }
        state.device = MobilePairedDevice(
            relayURL: offer.relayUrl,
            relaySigningPublicKey: offer.relaySigningPublicKey,
            deviceId: claimed.deviceId,
            deviceName: claimed.deviceName,
            keyId: claimed.keyId,
            stateKey: mobileBase64URL(keyData),
            nextSequence: 0
        )
        try keychain.save(state)
        secureState = state
        updateStatus()
        requestPublish(reason: "paired")
    }

    private func requestPublish(reason: String) {
        guard secureState?.device != nil, projectedState != nil else {
            updateStatus()
            return
        }
        publishRequested = true
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            guard let self else { return }
            while self.publishRequested && !Task.isCancelled {
                self.publishRequested = false
                do {
                    try await self.publishLatest()
                    self.updateStatus()
                } catch is CancellationError {
                    return
                } catch {
                    self.statusHandler("Mobile: Retrying — \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(5))
                    self.publishRequested = true
                }
            }
            self.publishTask = nil
        }
    }

    private func publishLatest() async throws {
        guard var state = secureState,
              var device = state.device,
              let projectedState,
              let key = mobileDecodeBase64URL(device.stateKey)
        else { return }

        while true {
            let sequence = device.nextSequence
            device.nextSequence += 1
            state.device = device
            try keychain.save(state)
            secureState = state
            let envelope = try MobileEnvelopeCodec.seal(
                projected: projectedState,
                updatedAt: updatedAt,
                sequence: sequence,
                hostId: state.host.hostId,
                deviceId: device.deviceId,
                keyId: device.keyId,
                stateKey: key
            )
            do {
                let response = try await client.publish(
                    envelope: envelope,
                    relayURL: device.relayURL,
                    token: state.host.hostAccessToken
                )
                guard response.accepted, response.sequence == sequence else {
                    throw MobileSyncError.invalidResponse
                }
                return
            } catch MobileSyncError.relay(_, let code, _, let minimumSequence)
                where code == "sequence_replay" && minimumSequence != nil {
                device.nextSequence = max(device.nextSequence, minimumSequence!)
                state.device = device
                continue
            }
        }
    }

    private func updateStatus() {
        guard let device = secureState?.device else {
            let configured = defaults.string(forKey: "mobileRelayURL") != nil
                && defaults.string(forKey: "mobileRelaySigningPublicKey") != nil
            statusHandler(configured ? "Mobile: Not paired" : "Mobile: Not configured")
            return
        }
        statusHandler("Mobile: Connected to \(device.deviceName)")
    }
}

func runMobileSyncSelfTests() -> Bool {
    let now = Date(timeIntervalSince1970: 10_000)
    let codex = LiveSourceCandidate(
        source: "Codex",
        bridgePrefix: "codex",
        lastActivity: now,
        state: .needs,
        detail: "must not leave the Mac"
    )
    let dsh = LiveSourceCandidate(
        source: "DSH",
        bridgePrefix: "dsh",
        lastActivity: now.addingTimeInterval(-1),
        state: .idle,
        detail: "must not leave the Mac either"
    )
    let projected = MobileProjectedState.make(driver: codex, candidates: [codex, dsh])
    guard projected.source == "codex", projected.status == "needs_input" else { return false }
    guard projected.sources == [
        MobileSourceSnapshot(id: "codex", label: "Codex", online: true, status: "needs_input"),
        MobileSourceSnapshot(id: "dsh", label: "DSH", online: true, status: "idle")
    ] else { return false }
    let offline = MobileProjectedState.make(driver: nil, candidates: [])
    guard offline.source == "none", offline.status == "idle",
          offline.sources.allSatisfy({ !$0.online && $0.status == nil }) else { return false }

    let offer = MobilePairingOffer(
        version: 1,
        type: "pairing_offer",
        relayUrl: "https://relay.example.test",
        pairingId: "pair_test",
        oneTimeToken: mobileBase64URL(Data(repeating: 1, count: 32)),
        hostId: "mac_test",
        hostName: "Test Mac",
        hostPublicKey: mobileBase64URL(Data(repeating: 2, count: 32)),
        kdfSalt: mobileBase64URL(Data(repeating: 3, count: 32)),
        relaySigningPublicKey: mobileBase64URL(Data(repeating: 4, count: 32)),
        expiresAt: mobileISO8601.string(from: Date(timeIntervalSince1970: 20_000))
    )
    guard let code = MobilePairingCode.encode(offer), MobilePairingCode.decode(code) == offer else {
        return false
    }

    let key = Data(0..<32)
    guard let envelope = try? MobileEnvelopeCodec.seal(
        projected: projected,
        updatedAt: now,
        sequence: 42,
        hostId: "mac_test",
        deviceId: "phone_test",
        keyId: "key_test",
        stateKey: key,
        sentAt: now
    ),
    let nonceData = mobileDecodeBase64URL(envelope.nonce),
    let encrypted = mobileDecodeBase64URL(envelope.ciphertext),
    encrypted.count > 16,
    let nonce = try? AES.GCM.Nonce(data: nonceData),
    let box = try? AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: encrypted.dropLast(16),
        tag: encrypted.suffix(16)
    ),
    let plaintext = try? AES.GCM.open(
        box,
        using: SymmetricKey(data: key),
        authenticating: Data("discipline:v1:mac_test:phone_test:42:key_test".utf8)
    ),
    let message = try? JSONDecoder().decode(MobileStateMessage.self, from: plaintext)
    else { return false }
    return message.sequence == 42
        && message.source == "codex"
        && message.status == "needs_input"
        && !String(decoding: plaintext, as: UTF8.self).contains("must not leave")
}
