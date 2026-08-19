import AppKit
import Darwin
import Foundation
import WebKit

enum PetState: String, CaseIterable {
    case idle
    case running
    case needs
    case ready
    case blocked

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .needs: return "Needs input"
        case .ready: return "Ready"
        case .blocked: return "Blocked"
        }
    }
}

struct SessionFileState {
    var threadID: String?
    var offset: UInt64 = 0
    var remainder = Data()
    var active = false
    var needsInput = false
    var pendingRequestID: String?
    var readyUntil: Date?
    var blocked = false   // 粘住：直到恢复事件才清除（对齐 DSH 语义）
    var blockedAt: Date?  // 出错时间；兜底只在最近 30 分钟内把它视为有效 blocked
    var lastActivity = Date.distantPast
    var modificationDate = Date.distantPast
}

enum RolloutEventParser {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO8601 = ISO8601DateFormatter()

    static func apply(line: Data, to state: inout SessionFileState, now: Date = Date()) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return }

        let payload = root["payload"] as? [String: Any] ?? [:]
        let envelopeType = root["type"] as? String ?? ""
        let payloadType = payload["type"] as? String ?? ""
        let method = root["method"] as? String ?? payload["method"] as? String ?? ""
        let name = payload["name"] as? String ?? ""
        let eventDate = parseDate(root["timestamp"] as? String) ?? now

        state.lastActivity = max(state.lastActivity, eventDate)

        if envelopeType == "session_meta" {
            state.threadID = payload["id"] as? String
                ?? payload["session_id"] as? String
                ?? state.threadID
            return
        }

        if envelopeType == "event_msg" && payloadType == "task_started" {
            state.active = true
            state.needsInput = false
            state.pendingRequestID = nil
            state.readyUntil = nil
            state.blocked = false
            state.blockedAt = nil
            return
        }

        if envelopeType == "event_msg" && payloadType == "task_complete" {
            state.active = false
            state.needsInput = false
            state.pendingRequestID = nil
            state.readyUntil = eventDate.addingTimeInterval(60)
            return
        }

        if payloadType == "turn_aborted" || payloadType == "task_failed" || payloadType == "stream_error" {
            state.active = false
            state.needsInput = false
            state.pendingRequestID = nil
            state.readyUntil = nil
            state.blocked = true   // 粘住：直到恢复事件
            state.blockedAt = eventDate
            return
        }

        // Codex Desktop's persisted rollout does not currently retain every
        // live app-server approval notification. It does retain the wrapped
        // tool call before the approval is answered, including the escalation
        // marker, followed by a matching tool output after resolution.
        if payloadType == "custom_tool_call",
           let input = payload["input"] as? String,
           requestsEscalatedPermission(input) {
            state.active = true
            state.needsInput = true
            state.pendingRequestID = payload["call_id"] as? String
                ?? payload["id"] as? String
            state.readyUntil = nil
            state.blocked = false   // 批准请求 = 恢复活动
            state.blockedAt = nil
            return
        }

        if method == "thread/status/changed", let status = payload["status"] as? [String: Any] {
            applyRuntimeStatus(status, to: &state, at: eventDate)
            return
        }

        let normalizedSignal = "\(payloadType) \(method) \(name)".lowercased()
        if normalizedSignal.contains("requestuserinput")
            || normalizedSignal.contains("request_user_input")
            || normalizedSignal.contains("requestapproval")
            || normalizedSignal.contains("request_approval") {
            state.active = true
            state.needsInput = true
            state.pendingRequestID = payload["call_id"] as? String
                ?? payload["requestId"] as? String
                ?? payload["id"] as? String
            state.blocked = false   // 请求输入/批准 = 恢复活动
            state.blockedAt = nil
            return
        }

        if normalizedSignal.contains("serverrequest/resolved")
            || normalizedSignal.contains("server_request_resolved") {
            state.needsInput = false
            state.pendingRequestID = nil
            if state.active {
                state.readyUntil = nil
            }
            return
        }

        if payloadType == "custom_tool_call_output" || payloadType == "function_call_output" {
            let callID = payload["call_id"] as? String
            if state.pendingRequestID == nil || callID == state.pendingRequestID {
                state.needsInput = false
                state.pendingRequestID = nil
            }
        }
    }

    static func aggregate(_ states: [SessionFileState], now: Date = Date()) -> (PetState, String) {
        let recentStates = states.filter { now.timeIntervalSince($0.modificationDate) < 86_400 }
        let active = recentStates.filter {
            $0.active && now.timeIntervalSince($0.modificationDate) < 1_800
        }

        if let waiting = active.max(by: { $0.lastActivity < $1.lastActivity }), waiting.needsInput {
            return (.needs, "A task needs input")
        }

        if recentStates.contains(where: { $0.blocked && blockedRecent($0.blockedAt, now: now) }) {
            return (.blocked, "A task was blocked")
        }

        if !active.isEmpty {
            let noun = active.count == 1 ? "task" : "tasks"
            return (.running, "\(active.count) \(noun) running")
        }

        if recentStates.contains(where: { ($0.readyUntil ?? .distantPast) > now }) {
            return (.ready, "A task completed")
        }

        return (.idle, "No active tasks")
    }

    private static func applyRuntimeStatus(
        _ status: [String: Any],
        to state: inout SessionFileState,
        at date: Date
    ) {
        let type = status["type"] as? String ?? ""
        let flags = status["activeFlags"] as? [String] ?? []

        switch type {
        case "active":
            state.active = true
            state.blocked = false   // 恢复活动，清除粘住
            state.blockedAt = nil
            state.needsInput = flags.contains("waitingOnApproval")
                || flags.contains("waitingOnUserInput")
        case "systemError":
            state.active = false
            state.needsInput = false
            state.blocked = true   // 粘住：直到恢复事件
            state.blockedAt = date
        case "idle", "notLoaded":
            state.active = false
            state.needsInput = false
        default:
            break
        }
    }

    /// 兜底的 blocked 只在出错后 30 分钟内有效：陈旧故障（如昨天出错的会话）不报红。
    /// DSH 路径的粘住 blocked 由插件按会话实时跟踪，不受此窗口限制。
    private static func blockedRecent(_ blockedAt: Date?, now: Date) -> Bool {
        guard let blockedAt else { return false }
        return now.timeIntervalSince(blockedAt) < 1_800
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalISO8601.date(from: value) ?? basicISO8601.date(from: value)
    }

    private static func requestsEscalatedPermission(_ input: String) -> Bool {
        let normalized = input.lowercased()
        return normalized.contains("sandbox_permissions")
            && normalized.contains("require_escalated")
    }
}

struct LiveRuntimeSnapshot: Equatable {
    let state: PetState
    let detail: String
}

struct LiveThreadStatus: Equatable {
    var type: String
    var activeFlags: [String]

    init?(dictionary: [String: Any]) {
        guard let type = dictionary["type"] as? String else { return nil }
        self.type = type
        self.activeFlags = dictionary["activeFlags"] as? [String] ?? []
    }

    init(type: String, activeFlags: [String] = []) {
        self.type = type
        self.activeFlags = activeFlags
    }
}

enum RuntimeStatusReducer {
    static func snapshot(from statuses: [LiveThreadStatus]) -> LiveRuntimeSnapshot? {
        guard !statuses.isEmpty else { return nil }

        let activeStatuses = statuses.filter { $0.type == "active" }
        let waitingCount = activeStatuses.filter { status in
            status.activeFlags.contains("waitingOnApproval")
                || status.activeFlags.contains("waitingOnUserInput")
        }.count

        if waitingCount > 0 {
            let noun = waitingCount == 1 ? "task" : "tasks"
            return LiveRuntimeSnapshot(
                state: .needs,
                detail: "\(waitingCount) \(noun) waiting for input — live Codex status"
            )
        }

        if statuses.contains(where: { $0.type == "systemError" }) {
            return LiveRuntimeSnapshot(state: .blocked, detail: "A task hit a system error — live Codex status")
        }

        if !activeStatuses.isEmpty {
            let noun = activeStatuses.count == 1 ? "task" : "tasks"
            return LiveRuntimeSnapshot(
                state: .running,
                detail: "\(activeStatuses.count) \(noun) running — live Codex status"
            )
        }

        return LiveRuntimeSnapshot(state: .idle, detail: "No active tasks — live Codex follower")
    }
}

struct IPCFrameDecoder {
    private(set) var buffer = Data()

    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []

        while buffer.count >= 4 {
            let length = Int(buffer[0])
                | (Int(buffer[1]) << 8)
                | (Int(buffer[2]) << 16)
                | (Int(buffer[3]) << 24)

            guard length > 0, length <= 256 * 1_024 * 1_024 else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard buffer.count >= length + 4 else { break }

            let payload = buffer.subdata(in: 4..<(length + 4))
            buffer.removeSubrange(0..<(length + 4))
            guard
                let object = try? JSONSerialization.jsonObject(with: payload),
                let message = object as? [String: Any]
            else { continue }
            messages.append(message)
        }

        return messages
    }

    static func encode(_ object: [String: Any]) -> Data? {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        guard payload.count <= Int(UInt32.max) else { return nil }

        let length = UInt32(payload.count)
        var frame = Data(capacity: payload.count + 4)
        frame.append(UInt8(length & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(payload)
        return frame
    }
}

final class CodexIPCStatusMonitor {
    typealias Callback = (LiveRuntimeSnapshot?) -> Void
    typealias DiagnosticCallback = (String) -> Void

    private struct Subscription {
        let ownerID: String
        var status: LiveThreadStatus?
    }

    private let socketPath: String
    private let callback: Callback
    private let diagnosticCallback: DiagnosticCallback
    private let queue = DispatchQueue(label: "com.zhylee.discipline.codex-ipc", qos: .utility)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var refreshTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var decoder = IPCFrameDecoder()
    private var clientID: String?
    private var initializeRequestID: String?
    private var discoveryRequests: [String: String] = [:]
    private var candidateThreadIDs = Set<String>()
    private var subscriptions: [String: Subscription] = [:]
    private var stopping = false
    private var lastPublished: LiveRuntimeSnapshot?
    private var hasPublishedLiveValue = false
    private var lastDiagnostic = ""

    init(
        socketPath: String,
        callback: @escaping Callback,
        diagnosticCallback: @escaping DiagnosticCallback
    ) {
        self.socketPath = socketPath
        self.callback = callback
        self.diagnosticCallback = diagnosticCallback
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = false
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.disconnect(scheduleReconnect: false)
        }
    }

    func updateCandidateThreadIDs(_ threadIDs: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let updated = Set(threadIDs)
            let removed = self.candidateThreadIDs.subtracting(updated)
            for threadID in removed {
                if let subscription = self.subscriptions[threadID] {
                    self.sendFollowing(
                        threadID: threadID,
                        ownerID: subscription.ownerID,
                        following: false
                    )
                }
                self.subscriptions.removeValue(forKey: threadID)
            }

            self.candidateThreadIDs = updated
            self.discoveryRequests = self.discoveryRequests.filter { updated.contains($0.value) }
            self.publishCurrentSnapshot()
            self.refreshSubscriptions()
        }
    }

    private func connect() {
        guard !stopping, socketFD < 0 else { return }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            report("Bridge: waiting for Codex Desktop")
            scheduleReconnect()
            return
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            report("Bridge: could not create local socket")
            scheduleReconnect()
            return
        }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        let addressLength = socklen_t(pathOffset + pathBytes.count)
        address.sun_len = UInt8(min(Int(addressLength), Int(UInt8.max)))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, addressLength)
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            report("Bridge: Codex IPC connection failed (\(errno))")
            scheduleReconnect()
            return
        }

        socketFD = fd
        decoder = IPCFrameDecoder()
        clientID = nil
        discoveryRequests.removeAll()
        subscriptions.removeAll()
        report("Bridge: connected; initializing follower sync…")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailableData() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()

        let requestID = UUID().uuidString
        initializeRequestID = requestID
        send([
            "type": "request",
            "requestId": requestID,
            "method": "initialize",
            "params": ["clientType": "discipline-status-monitor"]
        ])
    }

    private func readAvailableData() {
        guard socketFD >= 0 else { return }
        let suggestedCount = max(1, min(Int(readSource?.data ?? 1), 256 * 1_024))
        var bytes = [UInt8](repeating: 0, count: suggestedCount)
        let count = Darwin.read(socketFD, &bytes, bytes.count)

        guard count > 0 else {
            disconnect(scheduleReconnect: true)
            return
        }

        let data = Data(bytes.prefix(Int(count)))
        for message in decoder.append(data) {
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""

        if type == "client-discovery-request", let requestID = message["requestId"] as? String {
            send([
                "type": "client-discovery-response",
                "requestId": requestID,
                "response": ["canHandle": false]
            ])
            return
        }

        if type == "broadcast" {
            handleBroadcast(message)
            return
        }

        guard type == "response", let requestID = message["requestId"] as? String else { return }

        if requestID == initializeRequestID {
            initializeRequestID = nil
            guard
                (message["resultType"] as? String) == "success",
                let result = message["result"] as? [String: Any],
                let id = result["clientId"] as? String
            else {
                disconnect(scheduleReconnect: true)
                return
            }
            clientID = id
            report("Bridge: follower sync ready; discovering active tasks…")
            refreshSubscriptions()
            startRefreshing()
            return
        }

        guard let threadID = discoveryRequests.removeValue(forKey: requestID) else { return }
        guard candidateThreadIDs.contains(threadID) else { return }

        guard
            (message["resultType"] as? String) == "success",
            let ownerID = message["handledByClientId"] as? String
        else {
            reportBridgeSummary()
            return
        }

        subscriptions[threadID] = Subscription(ownerID: ownerID, status: nil)
        sendFollowing(threadID: threadID, ownerID: ownerID, following: true)
        report("Bridge: owner found; waiting for live task snapshot…")
    }

    private func handleBroadcast(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let sourceClientID = message["sourceClientId"] as? String
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "thread-stream-state-changed":
            guard
                params["hostId"] as? String == "local",
                let threadID = params["conversationId"] as? String,
                candidateThreadIDs.contains(threadID),
                let change = params["change"] as? [String: Any]
            else { return }

            if let sourceClientID {
                let currentStatus = subscriptions[threadID]?.status
                subscriptions[threadID] = Subscription(ownerID: sourceClientID, status: currentStatus)
            }
            applyStreamChange(change, to: threadID)

        case "thread-stream-following-status-requested":
            guard
                params["hostId"] as? String == "local",
                let threadID = params["conversationId"] as? String,
                candidateThreadIDs.contains(threadID),
                let sourceClientID
            else { return }

            let currentStatus = subscriptions[threadID]?.status
            subscriptions[threadID] = Subscription(ownerID: sourceClientID, status: currentStatus)
            sendFollowing(threadID: threadID, ownerID: sourceClientID, following: true)

        case "client-status-changed":
            guard
                params["status"] as? String == "disconnected",
                let disconnectedID = params["clientId"] as? String
            else { return }

            let affected = subscriptions.compactMap { threadID, subscription in
                subscription.ownerID == disconnectedID ? threadID : nil
            }
            for threadID in affected {
                subscriptions.removeValue(forKey: threadID)
            }
            publishCurrentSnapshot()
            refreshSubscriptions()

        default:
            break
        }
    }

    private func startRefreshing() {
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.5, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.refreshSubscriptions() }
        refreshTimer = timer
        timer.resume()
    }

    private func refreshSubscriptions() {
        guard let clientID, socketFD >= 0 else { return }

        let pendingThreadIDs = Set(discoveryRequests.values)
        for threadID in candidateThreadIDs.sorted()
            where subscriptions[threadID] == nil && !pendingThreadIDs.contains(threadID) {
            requestOwner(for: threadID, clientID: clientID)
        }

        reportBridgeSummary()
    }

    private func requestOwner(for threadID: String, clientID: String) {
        let requestID = UUID().uuidString
        discoveryRequests[requestID] = threadID
        send([
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": 1,
            "method": "thread-owner-discovery",
            "params": [
                "hostId": "local",
                "conversationId": threadID
            ],
            "timeoutMs": 4_000
        ])

        queue.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self, self.discoveryRequests.removeValue(forKey: requestID) != nil else { return }
            self.reportBridgeSummary()
        }
    }

    private func sendFollowing(threadID: String, ownerID: String, following: Bool) {
        guard let clientID, socketFD >= 0 else { return }
        send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "targetClientIds": [ownerID],
            "version": 1,
            "params": [
                "conversationId": threadID,
                "hostId": "local",
                "following": following
            ]
        ])
    }

    private func applyStreamChange(_ change: [String: Any], to threadID: String) {
        var subscription = subscriptions[threadID]
        let currentStatus = subscription?.status
        subscription?.status = Self.reduceStatus(change: change, current: currentStatus)

        if let subscription {
            subscriptions[threadID] = subscription
        }
        publishCurrentSnapshot()
        reportBridgeSummary()
    }

    static func reduceStatus(
        change: [String: Any],
        current: LiveThreadStatus?
    ) -> LiveThreadStatus? {
        let changeType = change["type"] as? String ?? ""
        var status = current

        if changeType == "snapshot",
           let conversation = change["conversationState"] as? [String: Any],
           let discovered = findRuntimeStatus(in: conversation) {
            status = discovered
        } else if changeType == "patches", let patches = change["patches"] as? [[String: Any]] {
            for patch in patches {
                applyStatusPatch(patch, to: &status)
            }
        }
        return status
    }

    private static func applyStatusPatch(_ patch: [String: Any], to status: inout LiveThreadStatus?) {
        if let value = patch["value"], let discovered = findRuntimeStatus(in: value) {
            status = discovered
            return
        }

        let path = patchPath(patch["path"])
        guard let statusIndex = path.firstIndex(of: "threadRuntimeStatus") else { return }
        let suffix = Array(path.dropFirst(statusIndex + 1))
        let operation = patch["op"] as? String ?? "replace"

        if suffix.isEmpty {
            if operation == "remove" {
                status = LiveThreadStatus(type: "notLoaded")
            } else if let dictionary = patch["value"] as? [String: Any] {
                status = LiveThreadStatus(dictionary: dictionary)
            }
            return
        }

        if suffix.first == "type", let value = patch["value"] as? String {
            var updated = status ?? LiveThreadStatus(type: value)
            updated.type = value
            status = updated
        } else if suffix.first == "activeFlags" {
            var updated = status ?? LiveThreadStatus(type: "active")
            if suffix.count == 1 {
                updated.activeFlags = operation == "remove" ? [] : (patch["value"] as? [String] ?? [])
            } else if let index = Int(suffix[1]) {
                if operation == "remove", updated.activeFlags.indices.contains(index) {
                    updated.activeFlags.remove(at: index)
                } else if let value = patch["value"] as? String {
                    if operation == "add", index <= updated.activeFlags.count {
                        updated.activeFlags.insert(value, at: index)
                    } else if updated.activeFlags.indices.contains(index) {
                        updated.activeFlags[index] = value
                    } else {
                        updated.activeFlags.append(value)
                    }
                }
            }
            status = updated
        }
    }

    private static func findRuntimeStatus(in value: Any) -> LiveThreadStatus? {
        if let dictionary = value as? [String: Any] {
            if let statusDictionary = dictionary["threadRuntimeStatus"] as? [String: Any],
               let status = LiveThreadStatus(dictionary: statusDictionary) {
                return status
            }
            for nested in dictionary.values {
                if let status = findRuntimeStatus(in: nested) { return status }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let status = findRuntimeStatus(in: nested) { return status }
            }
        }
        return nil
    }

    private static func patchPath(_ value: Any?) -> [String] {
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] {
            return values.compactMap { element in
                if let string = element as? String { return string }
                if let number = element as? NSNumber { return number.stringValue }
                return nil
            }
        }
        if let string = value as? String {
            return string.split(separator: "/").map(String.init)
        }
        return []
    }

    private func publishCurrentSnapshot() {
        let statuses = subscriptions.values.compactMap(\.status)
        publish(RuntimeStatusReducer.snapshot(from: statuses))
    }

    private func reportBridgeSummary() {
        guard clientID != nil else { return }
        let statuses = subscriptions.values.compactMap(\.status)
        let activeCount = statuses.filter { $0.type == "active" }.count
        let waitingCount = statuses.filter {
            $0.activeFlags.contains("waitingOnApproval")
                || $0.activeFlags.contains("waitingOnUserInput")
        }.count

        if candidateThreadIDs.isEmpty {
            report("Bridge: live follower ready · no active tasks")
        } else if statuses.isEmpty {
            report("Bridge: live follower · locating \(candidateThreadIDs.count) task owner(s)…")
        } else {
            report("Bridge: live follower · \(activeCount) active · \(waitingCount) waiting")
        }
    }

    private func send(_ object: [String: Any]) {
        guard socketFD >= 0, let frame = IPCFrameDecoder.encode(object) else { return }
        let result = frame.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(socketFD, base.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else { return -1 }
                written += count
            }
            return written
        }
        if result < 0 {
            disconnect(scheduleReconnect: true)
        }
    }

    private func publish(_ snapshot: LiveRuntimeSnapshot?) {
        if hasPublishedLiveValue, snapshot == lastPublished { return }
        hasPublishedLiveValue = true
        lastPublished = snapshot
        DispatchQueue.main.async { [callback] in callback(snapshot) }
    }

    private func report(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        DispatchQueue.main.async { [diagnosticCallback] in diagnosticCallback(message) }
    }

    private func disconnect(scheduleReconnect: Bool) {
        refreshTimer?.cancel()
        refreshTimer = nil
        initializeRequestID = nil
        clientID = nil
        discoveryRequests.removeAll()
        subscriptions.removeAll()
        decoder = IPCFrameDecoder()

        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1

        if hasPublishedLiveValue {
            hasPublishedLiveValue = false
            lastPublished = nil
            DispatchQueue.main.async { [callback] in callback(nil) }
        }

        report("Bridge: follower disconnected; using session fallback")

        if scheduleReconnect, !stopping {
            self.scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopping, reconnectWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }
}

final class SessionMonitor {
    typealias Callback = (PetState, String, [String]) -> Void

    private let root: URL
    private let callback: Callback
    private let queue = DispatchQueue(label: "com.zhylee.discipline.session-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var files: [String: SessionFileState] = [:]
    private var lastPublishedState: PetState?
    private var lastPublishedDetail = ""
    private var lastPublishedThreadIDs: [String] = []

    init(root: URL, callback: @escaping Callback) {
        self.root = root
        self.callback = callback
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.poll()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.35, repeating: 0.35, leeway: .milliseconds(80))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func poll() {
        let urls = sessionFiles()
        let knownPaths = Set(urls.map(\.path))

        for path in files.keys where !knownPaths.contains(path) {
            files.removeValue(forKey: path)
        }

        for url in urls {
            update(url)
        }

        let result = RolloutEventParser.aggregate(Array(files.values))
        let candidateThreadIDs = files.values
            .filter { state in
                state.active && Date().timeIntervalSince(state.modificationDate) < 86_400
            }
            .sorted { $0.lastActivity > $1.lastActivity }
            .compactMap(\.threadID)
            .reduce(into: [String]()) { result, threadID in
                if !result.contains(threadID) && result.count < 8 {
                    result.append(threadID)
                }
            }

        if result.0 != lastPublishedState
            || result.1 != lastPublishedDetail
            || candidateThreadIDs != lastPublishedThreadIDs {
            lastPublishedState = result.0
            lastPublishedDetail = result.1
            lastPublishedThreadIDs = candidateThreadIDs
            DispatchQueue.main.async { [callback] in
                callback(result.0, result.1, candidateThreadIDs)
            }
        }
    }

    private func sessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    private func update(_ url: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber,
            let modificationDate = attributes[.modificationDate] as? Date
        else { return }

        let size = number.uint64Value
        var state = files[url.path] ?? SessionFileState()
        state.modificationDate = modificationDate
        if state.threadID == nil {
            state.threadID = threadID(from: url)
        }

        if state.offset == 0 && state.lastActivity == .distantPast {
            guard Date().timeIntervalSince(modificationDate) < 86_400 else {
                state.offset = size
                files[url.path] = state
                return
            }

            let tailSize = min(size, 8 * 1_024 * 1_024)
            let start = size - tailSize
            if let data = read(url, from: start) {
                state.offset = size
                consume(data, into: &state, discardFirstPartialLine: start > 0)
            }
            files[url.path] = state
            return
        }

        if size < state.offset {
            state = SessionFileState()
            state.modificationDate = modificationDate
        }

        guard size > state.offset, let data = read(url, from: state.offset) else {
            files[url.path] = state
            return
        }

        state.offset = size
        consume(data, into: &state, discardFirstPartialLine: false)
        files[url.path] = state
    }

    private func threadID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate.lowercased()
    }

    private func read(_ url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private func consume(
        _ appended: Data,
        into state: inout SessionFileState,
        discardFirstPartialLine: Bool
    ) {
        var combined = Data()
        combined.append(state.remainder)
        combined.append(appended)

        var lines = combined.split(separator: 0x0A, omittingEmptySubsequences: true)
        let hasTrailingNewline = combined.last == 0x0A

        if !hasTrailingNewline, let final = lines.popLast() {
            state.remainder = Data(final)
        } else {
            state.remainder.removeAll(keepingCapacity: true)
        }

        if discardFirstPartialLine && !lines.isEmpty {
            lines.removeFirst()
        }

        for line in lines {
            RolloutEventParser.apply(line: Data(line), to: &state)
        }
    }
}

final class PetRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded = false
    private var pendingState: PetState = .idle

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.isElementFullscreenEnabled = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
    }

    func load() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
            NSLog("Discipline could not find index.html")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func setState(_ state: PetState) {
        pendingState = state
        guard loaded else { return }
        webView.evaluateJavaScript("window.Discipline?.setState('\(state.rawValue)')")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        setState(pendingState)
    }
}

final class DragHostView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - DSH live status (方案 A)
// Reads $DSH_HOME/live-status.json written by the dsh-live-status plugin.
// heartbeatAt 新鲜 = DSH 在线；updatedAt = 最近活动；state/detail/diagnostic 由插件聚合。

struct DSHSessionRow: Decodable {
    let id: String
    let state: String
    let stateAt: Double
    let lastEventAt: Double
    let turn: Int?
    let pendingApproval: Bool?
}

struct DSHStatusPayload: Decodable {
    let source: String?
    let state: String
    let detail: String
    let diagnostic: String?
    let updatedAt: Double?
    let heartbeatAt: Double?
    let sessions: [DSHSessionRow]?
}

struct DSHLiveSnapshot: Equatable {
    let state: PetState
    let detail: String
    let diagnostic: String
    let lastEventAt: Date
    let heartbeatAt: Date
}

final class DSHStatusMonitor {
    enum Status: Equatable {
        case live(DSHLiveSnapshot)   // 文件新鲜，插件在线
        case stale                    // 文件存在但心跳过期
        case absent                   // 无状态文件
    }

    typealias Callback = (Status) -> Void

    private let url: URL
    private let callback: Callback
    private let queue = DispatchQueue(label: "com.zhylee.discipline.dsh-status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastPublished: Status?
    private let stalenessSeconds: TimeInterval = 30

    init(callback: @escaping Callback) {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".dsh", isDirectory: true).path
        url = URL(fileURLWithPath: home).appendingPathComponent("live-status.json")
        self.callback = callback
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.poll()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func poll() {
        guard let data = try? Data(contentsOf: url) else {
            publish(.absent)
            return
        }
        guard
            let payload = try? JSONDecoder().decode(DSHStatusPayload.self, from: data),
            let heartbeatMs = payload.heartbeatAt,
            let updatedMs = payload.updatedAt
        else {
            publish(.absent)
            return
        }

        let heartbeat = Date(timeIntervalSince1970: heartbeatMs / 1000)
        let now = Date()
        guard now.timeIntervalSince(heartbeat) < stalenessSeconds else {
            publish(.stale)
            return
        }

        let snapshot = DSHLiveSnapshot(
            state: PetState(rawValue: payload.state) ?? .idle,
            detail: payload.detail,
            diagnostic: payload.diagnostic ?? "",
            lastEventAt: Date(timeIntervalSince1970: updatedMs / 1000),
            heartbeatAt: heartbeat
        )
        publish(.live(snapshot))
    }

    private func publish(_ status: Status) {
        if status == lastPublished { return }
        lastPublished = status
        DispatchQueue.main.async { [callback] in callback(status) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var panel: PetPanel!
    private var renderer: PetRenderer!
    private var monitor: SessionMonitor!
    private var ipcMonitor: CodexIPCStatusMonitor!
    private var statusItem: NSStatusItem!
    private var sourceMenuItem: NSMenuItem!
    private var stateMenuItem: NSMenuItem!
    private var detailMenuItem: NSMenuItem!
    private var bridgeMenuItem: NSMenuItem!
    private var liveState: PetState = .idle
    private var liveDetail = "Starting status bridge…"
    private var liveSource = "DSH"
    private var liveBridge = "starting…"
    private var fallbackState: PetState = .idle
    private var fallbackDetail = "Starting session fallback…"
    private var runtimeSnapshot: LiveRuntimeSnapshot?
    private var dshMonitor: DSHStatusMonitor!
    private var dshStatus: DSHStatusMonitor.Status = .absent
    private var codexDiagnostic = ""
    private var codexLastActivityAt = Date.distantPast
    private var previewWorkItem: DispatchWorkItem?
    private var dshLaunchInProgress = false
    private var dshLaunchProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        makeStatusMenu()

        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock", isDirectory: false)
        ipcMonitor = CodexIPCStatusMonitor(
            socketPath: socket.path,
            callback: { [weak self] snapshot in
                self?.receiveRuntimeSnapshot(snapshot)
            },
            diagnosticCallback: { [weak self] diagnostic in
                self?.codexDiagnostic = diagnostic
                self?.refreshEffectiveState()
            }
        )

        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        monitor = SessionMonitor(root: sessions) { [weak self] state, detail, threadIDs in
            self?.receiveFallbackState(state, detail: detail)
            self?.ipcMonitor.updateCandidateThreadIDs(threadIDs)
        }

        dshMonitor = DSHStatusMonitor { [weak self] status in
            self?.receiveDSHStatus(status)
        }

        ipcMonitor.start()
        monitor.start()
        dshMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        ipcMonitor?.stop()
        dshMonitor?.stop()
        if let dshLaunchProcess, dshLaunchProcess.isRunning {
            dshLaunchProcess.terminate()
        }
    }

    private func makePanel() {
        let size = NSSize(width: 190, height: 190)
        let savedOrigin = savedPanelOrigin(size: size)
        panel = PetPanel(
            contentRect: NSRect(origin: savedOrigin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        renderer = PetRenderer()
        let host = DragHostView(frame: NSRect(origin: .zero, size: size))
        renderer.webView.frame = host.bounds
        host.addSubview(renderer.webView)
        panel.contentView = host
        panel.orderFrontRegardless()
        renderer.load()
    }

    private func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarIcon()
        }

        let menu = NSMenu(title: "Discipline")
        menu.delegate = self

        sourceMenuItem = NSMenuItem(title: liveSource, action: nil, keyEquivalent: "")
        sourceMenuItem.isEnabled = false
        menu.addItem(sourceMenuItem)

        stateMenuItem = NSMenuItem(title: "State: Idle", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)

        detailMenuItem = NSMenuItem(title: liveDetail, action: nil, keyEquivalent: "")
        detailMenuItem.isEnabled = false
        menu.addItem(detailMenuItem)

        bridgeMenuItem = NSMenuItem(title: "Bridge: starting…", action: nil, keyEquivalent: "")
        bridgeMenuItem.isEnabled = false
        menu.addItem(bridgeMenuItem)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        let openMenu = NSMenu(title: "Open")
        let dshItem = NSMenuItem(title: "Open DSH", action: #selector(openDSH), keyEquivalent: "")
        dshItem.target = self
        openMenu.addItem(dshItem)
        let gptItem = NSMenuItem(title: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "")
        gptItem.target = self
        openMenu.addItem(gptItem)
        open.submenu = openMenu
        menu.addItem(open)

        let preview = NSMenuItem(title: "Preview state", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu(title: "Preview state")
        for state in PetState.allCases {
            let item = NSMenuItem(
                title: state.displayName,
                action: #selector(previewState(_:)),
                keyEquivalent: ""
            )
            item.representedObject = state.rawValue
            previewMenu.addItem(item)
        }
        preview.submenu = previewMenu
        menu.addItem(preview)

        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(togglePanel), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Discipline", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        for item in openMenu.items {
            item.target = self
        }
        for item in previewMenu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func receiveFallbackState(_ state: PetState, detail: String) {
        fallbackState = state
        fallbackDetail = detail
        refreshEffectiveState()
    }

    private func receiveRuntimeSnapshot(_ snapshot: LiveRuntimeSnapshot?) {
        runtimeSnapshot = snapshot
        if let snapshot, snapshot.state != .idle {
            codexLastActivityAt = Date()
        }
        refreshEffectiveState()
    }

    private func receiveDSHStatus(_ status: DSHStatusMonitor.Status) {
        dshStatus = status
        refreshEffectiveState()
    }

    private struct LiveCandidate {
        let source: String       // 显示名："DSH" / "Codex"
        let bridgePrefix: String // 桥前缀："dsh" / "codex"
        let lastActivity: Date
        let state: PetState
        let detail: String
    }

    /// 活动抢占：谁最近在干活谁驱动；都空闲时取最近 30 分钟内动过的；都没有 → 无驱动源（中立）。
    /// 两个源地位平等、无默认优先级——用谁谁就是主。
    private func refreshEffectiveState() {
        var candidates: [LiveCandidate] = []

        if case .live(let snap) = dshStatus {
            candidates.append(LiveCandidate(
                source: "DSH",
                bridgePrefix: "dsh",
                lastActivity: snap.lastEventAt,
                state: snap.state,
                detail: snap.detail
            ))
        }
        if let snap = runtimeSnapshot {
            candidates.append(LiveCandidate(
                source: "Codex",
                bridgePrefix: "codex",
                lastActivity: codexLastActivityAt,
                state: snap.state,
                detail: snap.detail
            ))
        }

        let active = candidates.filter { $0.state != .idle }
        let recentlyUsed = candidates.filter { $0.lastActivity > Date().addingTimeInterval(-30 * 60) }
        let driver = active.max(by: { $0.lastActivity < $1.lastActivity })
            ?? recentlyUsed.max(by: { $0.lastActivity < $1.lastActivity })

        if let driver {
            var state = driver.state
            var detail = driver.detail
            // Codex 的 ready/blocked 闪烁来自会话日志兜底（DSH 由插件自带）
            if driver.source == "Codex", state == .idle,
               fallbackState == .ready || fallbackState == .blocked {
                state = fallbackState
                detail = fallbackDetail
            }
            liveState = state
            liveDetail = detail
            liveSource = driver.source
            liveBridge = bridgeLine(for: driver)
            guard previewWorkItem == nil else { return }
            apply(state, detail: detail, source: driver.source, bridge: liveBridge)
        } else if !candidates.isEmpty {
            // 有在线源但都空闲且近期无活动：无驱动源（中立），状态为 idle
            liveState = .idle
            liveDetail = "No active tasks"
            liveSource = "—"
            liveBridge = "—"
            guard previewWorkItem == nil else { return }
            apply(.idle, detail: "No active tasks", source: "—", bridge: "—")
        } else {
            // 无在线源：会话日志兜底
            liveState = fallbackState
            liveDetail = fallbackDetail
            liveSource = "Session logs"
            liveBridge = "session fallback"
            guard previewWorkItem == nil else { return }
            apply(fallbackState, detail: fallbackDetail, source: "Session logs", bridge: "session fallback")
        }
    }

    private func bridgeLine(for driver: LiveCandidate) -> String {
        if driver.bridgePrefix == "dsh" {
            if case .live(let snap) = dshStatus {
                var line = "dsh plugin live"
                if !snap.diagnostic.isEmpty {
                    line += " · " + snap.diagnostic
                }
                return line
            }
            return "dsh status stale"
        }
        var line = "codex \(codexConnectionStatus())"
        if let snap = runtimeSnapshot, snap.state != .idle {
            let suffix = codexActivitySuffix()
            if !suffix.isEmpty {
                line += " · " + suffix
            }
        }
        return line
    }

    private func codexConnectionStatus() -> String {
        let d = codexDiagnostic.lowercased()
        if d.contains("follower"), !d.contains("waiting"), !d.contains("disconnected") {
            return "follower ready"
        }
        return "reconnecting…"
    }

    private func codexActivitySuffix() -> String {
        guard let range = codexDiagnostic.range(of: "· ") else { return "" }
        let suffix = String(codexDiagnostic[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if suffix.lowercased().contains("no active") { return "" }
        return suffix
    }

    private func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "menu-bar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Discipline")
    }

    private func apply(_ state: PetState, detail: String, source: String, bridge: String) {
        renderer.setState(state)
        sourceMenuItem.title = source
        stateMenuItem.title = "State: \(state.displayName)"
        detailMenuItem.title = detail
        bridgeMenuItem.title = "Bridge: " + bridge
    }

    private func savedPanelOrigin(size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "panelX") != nil, defaults.object(forKey: "panelY") != nil {
            return NSPoint(x: defaults.double(forKey: "panelX"), y: defaults.double(forKey: "panelY"))
        }

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: visible.maxX - size.width - 28,
            y: visible.minY + 44
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "panelX")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "panelY")
    }

    func menuWillOpen(_ menu: NSMenu) {
        if previewWorkItem == nil {
            sourceMenuItem.title = liveSource
            stateMenuItem.title = "State: \(liveState.displayName)"
            detailMenuItem.title = liveDetail
            bridgeMenuItem.title = "Bridge: " + liveBridge
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func openChatGPT() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    }

    @objc private func openDSH() {
        probeDSH { [weak self] reachable in
            guard let self else { return }
            if reachable {
                NSWorkspace.shared.open(self.dshWebURL)
            } else {
                self.launchDSHAndOpen()
            }
        }
    }

    private let dshWebURL = URL(string: "http://127.0.0.1:3080")!

    private func probeDSH(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: dshWebURL)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion(response != nil)
        }.resume()
    }

    private func dshLaunchDirectory() -> URL {
        if let dir = UserDefaults.standard.string(forKey: "dshLaunchDir"), !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func launchDSHAndOpen() {
        guard !dshLaunchInProgress else { return }
        dshLaunchInProgress = true

        let workDir = dshLaunchDirectory()
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/discipline-launcher.log", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "-y", "@deepseek-ai/dsh", "web"]
        process.currentDirectoryURL = workDir
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            dshLaunchInProgress = false
            NSSound.beep()
            return
        }
        dshLaunchProcess = process

        let deadline = Date().addingTimeInterval(30)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date() < deadline {
                if self?.isDSHReachable() == true {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(self?.dshWebURL ?? URL(string: "http://127.0.0.1:3080")!)
                        self?.dshLaunchInProgress = false
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async { [weak self] in
                self?.dshLaunchInProgress = false
                NSSound.beep()
            }
        }
    }

    private func isDSHReachable() -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(3080).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    @objc private func previewState(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let state = PetState(rawValue: raw)
        else { return }

        previewWorkItem?.cancel()
        apply(state, detail: "Preview — returning to live sync in 5 seconds",
              source: liveSource, bridge: liveBridge)

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewWorkItem = nil
            self.apply(self.liveState, detail: self.liveDetail,
                       source: self.liveSource, bridge: self.liveBridge)
        }
        previewWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func runSelfTests() -> Bool {
    var state = SessionFileState()
    state.modificationDate = Date()

    let sessionMeta = #"{"timestamp":"2026-08-18T12:00:00.000Z","type":"session_meta","payload":{"id":"01a014d8-03fc-7a32-b3fd-c5a7fef4a821"}}"#
    RolloutEventParser.apply(line: Data(sessionMeta.utf8), to: &state)
    guard state.threadID == "01a014d8-03fc-7a32-b3fd-c5a7fef4a821" else { return false }

    let started = #"{"timestamp":"2026-08-18T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
    RolloutEventParser.apply(line: Data(started.utf8), to: &state)
    guard state.active, RolloutEventParser.aggregate([state]).0 == .running else { return false }

    let waiting = #"{"timestamp":"2026-08-18T12:00:01.000Z","method":"thread/status/changed","payload":{"status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#
    RolloutEventParser.apply(line: Data(waiting.utf8), to: &state)
    guard state.needsInput, RolloutEventParser.aggregate([state]).0 == .needs else { return false }

    state.needsInput = false
    state.pendingRequestID = nil
    let escalated = #"{"timestamp":"2026-08-18T12:00:01.100Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_permission","name":"exec","input":"{\"sandbox_permissions\":\"require_escalated\"}"}}"#
    RolloutEventParser.apply(line: Data(escalated.utf8), to: &state)
    guard state.needsInput, state.pendingRequestID == "call_permission" else { return false }

    let resolved = #"{"timestamp":"2026-08-18T12:00:01.200Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_permission"}}"#
    RolloutEventParser.apply(line: Data(resolved.utf8), to: &state)
    guard !state.needsInput, RolloutEventParser.aggregate([state]).0 == .running else { return false }

    var otherCompleted = SessionFileState()
    otherCompleted.modificationDate = Date()
    otherCompleted.readyUntil = Date().addingTimeInterval(7)
    guard RolloutEventParser.aggregate([state, otherCompleted]).0 == .running else { return false }

    let completed = #"{"timestamp":"2099-08-18T12:00:02.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    RolloutEventParser.apply(line: Data(completed.utf8), to: &state)
    guard !state.active, RolloutEventParser.aggregate([state]).0 == .ready else { return false }

    var blocked = SessionFileState()
    blocked.modificationDate = Date()
    let aborted = #"{"timestamp":"2099-08-18T12:00:03.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#
    RolloutEventParser.apply(line: Data(aborted.utf8), to: &blocked)
    guard RolloutEventParser.aggregate([blocked]).0 == .blocked else { return false }

    let liveStatuses = [
        LiveThreadStatus(type: "active"),
        LiveThreadStatus(type: "active", activeFlags: ["waitingOnApproval"]),
        LiveThreadStatus(type: "idle")
    ]
    guard RuntimeStatusReducer.snapshot(from: liveStatuses)?.state == .needs else { return false }

    let runningStatuses = [
        LiveThreadStatus(type: "active"),
        LiveThreadStatus(type: "idle")
    ]
    guard RuntimeStatusReducer.snapshot(from: runningStatuses)?.state == .running else { return false }
    guard RuntimeStatusReducer.snapshot(from: []) == nil else { return false }

    let followerSnapshot: [String: Any] = [
        "type": "snapshot",
        "revision": 1,
        "conversationState": [
            "id": "waiting",
            "threadRuntimeStatus": [
                "type": "active",
                "activeFlags": ["waitingOnApproval"]
            ]
        ]
    ]
    var followerStatus = CodexIPCStatusMonitor.reduceStatus(change: followerSnapshot, current: nil)
    guard followerStatus?.activeFlags == ["waitingOnApproval"] else { return false }

    let approvalResolvedPatch: [String: Any] = [
        "type": "patches",
        "patches": [[
            "op": "remove",
            "path": ["threadRuntimeStatus", "activeFlags", 0]
        ]]
    ]
    followerStatus = CodexIPCStatusMonitor.reduceStatus(
        change: approvalResolvedPatch,
        current: followerStatus
    )
    guard followerStatus?.type == "active", followerStatus?.activeFlags.isEmpty == true else { return false }

    let approvalAddedPatch: [String: Any] = [
        "type": "patches",
        "patches": [[
            "op": "add",
            "path": ["threadRuntimeStatus", "activeFlags", 0],
            "value": "waitingOnApproval"
        ]]
    ]
    followerStatus = CodexIPCStatusMonitor.reduceStatus(
        change: approvalAddedPatch,
        current: followerStatus
    )
    guard followerStatus?.activeFlags == ["waitingOnApproval"] else { return false }

    let framedMessage: [String: Any] = [
        "type": "response",
        "requestId": "test",
        "result": ["ok": true]
    ]
    guard let frame = IPCFrameDecoder.encode(framedMessage), frame.count > 8 else { return false }
    var decoder = IPCFrameDecoder()
    let firstHalf = frame.prefix(frame.count / 2)
    let secondHalf = frame.suffix(from: frame.count / 2)
    guard decoder.append(Data(firstHalf)).isEmpty else { return false }
    let decoded = decoder.append(Data(secondHalf))
    guard decoded.count == 1, decoded[0]["requestId"] as? String == "test" else { return false }

    return true
}

if CommandLine.arguments.contains("--self-test") {
    let passed = runSelfTests()
    print(passed ? "Discipline self-test passed" : "Discipline self-test failed")
    exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
