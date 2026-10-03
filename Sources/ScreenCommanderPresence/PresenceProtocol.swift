import Foundation

/// Wire protocol between screencommander clients and the presence process.
///
/// Transport is newline-delimited JSON over a Unix domain socket. Every request
/// is one line, `{"id": 1, "method": "cursor.moveTo", "params": {...}}`, and
/// gets exactly one response line carrying the same id:
/// `{"id": 1, "ok": true, "result": {...}}` or
/// `{"id": 1, "ok": false, "error": {"code": "target_busy", "message": "..."}}`.
/// Responses on one connection can arrive out of order because `cursor.moveTo`
/// replies when the cursor arrives, so clients match on `id`.
public enum PresenceProtocol {
    /// Bumped on any incompatible change to a message shape or its meaning.
    /// Version 2: leases expire after an idle period whatever the connection
    /// does, `hello` always answers with the server's version, and `shutdown`
    /// is refused from a client that did not greet with this version or later.
    public static let version = 2
}

// MARK: - Shared value types

/// A point in global CoreGraphics coordinates: origin at the top-left of the
/// primary display, y growing downward.
public struct PresencePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// When `cursor.moveTo` replies.
public enum CursorMoveTiming: String, Codable, Equatable, Sendable {
    /// Reply once the glide is close enough to click (progress >= 0.995 or within ~3 pt).
    case closeEnough
    /// Reply once the spring has fully settled.
    case finished
}

/// Activity state shown by a session's cursor.
public enum CursorState: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case paused
}

public enum PresenceMethod: String, Codable, CaseIterable, Sendable {
    case hello
    case sessionAcquire = "session.acquire"
    case sessionRelease = "session.release"
    case cursorMoveTo = "cursor.moveTo"
    case cursorPress = "cursor.press"
    case cursorSetState = "cursor.setState"
    case cursorHide = "cursor.hide"
    case guardBegin = "guard.begin"
    case guardEnd = "guard.end"
    case status
    case resume
    case shutdown
}

public enum PresenceErrorCode: String, Codable, Equatable, Sendable {
    /// Another session holds the lease on the requested target pid.
    case targetBusy = "target_busy"
    /// The abort chord was pressed. Cleared by `resume`.
    case abortedByUser = "aborted_by_user"
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case unknownMethod = "unknown_method"
    case shuttingDown = "shutting_down"
}

public struct PresenceError: Codable, Equatable, Error, Sendable {
    public var code: PresenceErrorCode
    public var message: String

    public init(code: PresenceErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Result payload for messages that only acknowledge.
public struct PresenceEmpty: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - Request parameters

public struct HelloParams: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// The client's pid. The server ignores input events this pid posts when
    /// deciding whether the user is active.
    public var pid: Int32
    public var client: String?

    public init(protocolVersion: Int = PresenceProtocol.version, pid: Int32, client: String? = nil) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.client = client
    }
}

public struct SessionAcquireParams: Codable, Equatable, Sendable {
    public var session: String
    public var pid: Int32
    /// Whether the lease outlives the connection. Zero or absent releases it as
    /// soon as the client goes away (`serve`). A positive value keeps it after
    /// the client exits, until it goes idle and at most this long (one-shot CLI
    /// commands).
    public var holdMs: Int?
    /// The lease is released once the session has not acted on the target for
    /// this long, connected or not. Absent uses the server's default.
    public var idleMs: Int?
    /// How long the session's cursor stays on screen after its last request
    /// before it fades out. Absent uses the server's default.
    public var lingerMs: Int?

    public init(session: String, pid: Int32, holdMs: Int? = nil, idleMs: Int? = nil, lingerMs: Int? = nil) {
        self.session = session
        self.pid = pid
        self.holdMs = holdMs
        self.idleMs = idleMs
        self.lingerMs = lingerMs
    }
}

public struct SessionReleaseParams: Codable, Equatable, Sendable {
    public var session: String
    /// Releases this one lease. Absent releases every lease the session holds
    /// and ends the session, fading its cursor out.
    public var pid: Int32?

    public init(session: String, pid: Int32? = nil) {
        self.session = session
        self.pid = pid
    }
}

public struct CursorMoveParams: Codable, Equatable, Sendable {
    public var session: String
    public var point: PresencePoint
    /// The window the cursor sits above and follows. Absent floats the cursor
    /// at a high window level.
    public var windowID: UInt32?
    public var timing: CursorMoveTiming

    public init(session: String, point: PresencePoint, windowID: UInt32? = nil, timing: CursorMoveTiming = .closeEnough) {
        self.session = session
        self.point = point
        self.windowID = windowID
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case session, point, windowID, timing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        point = try container.decode(PresencePoint.self, forKey: .point)
        windowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID)
        timing = try container.decodeIfPresent(CursorMoveTiming.self, forKey: .timing) ?? .closeEnough
    }
}

public struct CursorPressParams: Codable, Equatable, Sendable {
    public var session: String
    public var count: Int

    public init(session: String, count: Int = 1) {
        self.session = session
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case session, count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

public struct CursorSetStateParams: Codable, Equatable, Sendable {
    public var session: String
    public var state: CursorState

    public init(session: String, state: CursorState) {
        self.session = session
        self.state = state
    }
}

public struct CursorHideParams: Codable, Equatable, Sendable {
    public var session: String

    public init(session: String) {
        self.session = session
    }
}

public struct GuardBeginParams: Codable, Equatable, Sendable {
    /// The target app's pid. If it activates itself during the lease, the app
    /// that was frontmost at `guard.begin` is put back.
    public var pid: Int32
    public var leaseMs: Int
    public var session: String?

    public init(pid: Int32, leaseMs: Int, session: String? = nil) {
        self.pid = pid
        self.leaseMs = leaseMs
        self.session = session
    }
}

public struct GuardEndParams: Codable, Equatable, Sendable {
    public var pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }
}

// MARK: - Results

public struct HelloResult: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverPID: Int32
    public var tapAvailable: Bool

    public init(protocolVersion: Int, serverPID: Int32, tapAvailable: Bool) {
        self.protocolVersion = protocolVersion
        self.serverPID = serverPID
        self.tapAvailable = tapAvailable
    }
}

public struct LeaseResult: Codable, Equatable, Sendable {
    public var session: String
    public var pid: Int32
    /// Index into the cursor palette, stable for the life of the session.
    public var colorIndex: Int

    public init(session: String, pid: Int32, colorIndex: Int) {
        self.session = session
        self.pid = pid
        self.colorIndex = colorIndex
    }
}

public struct CursorMoveResult: Codable, Equatable, Sendable {
    public var session: String
    /// Where the hotspot ended up, in global CG coordinates.
    public var point: PresencePoint
    /// False when the glide was cut short by a newer move, a hide, or shutdown.
    public var arrived: Bool
    /// False when the cursor is not on screen, for example because the target
    /// window is on another Space.
    public var visible: Bool
    public var cursorWindowID: UInt32?

    public init(session: String, point: PresencePoint, arrived: Bool, visible: Bool, cursorWindowID: UInt32?) {
        self.session = session
        self.point = point
        self.arrived = arrived
        self.visible = visible
        self.cursorWindowID = cursorWindowID
    }
}

public struct GuardResult: Codable, Equatable, Sendable {
    public var pid: Int32
    public var previousFrontmostPID: Int32?
    public var leaseMs: Int

    public init(pid: Int32, previousFrontmostPID: Int32?, leaseMs: Int) {
        self.pid = pid
        self.previousFrontmostPID = previousFrontmostPID
        self.leaseMs = leaseMs
    }
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var id: String
    /// Target pids this session holds leases on.
    public var pids: [Int32]
    /// True while real user input has reached a leased app within the quiet period.
    public var userActive: Bool
    public var lastUserInputMsAgo: Int?
    public var state: CursorState
    public var colorIndex: Int

    public init(id: String, pids: [Int32], userActive: Bool, lastUserInputMsAgo: Int?, state: CursorState, colorIndex: Int) {
        self.id = id
        self.pids = pids
        self.userActive = userActive
        self.lastUserInputMsAgo = lastUserInputMsAgo
        self.state = state
        self.colorIndex = colorIndex
    }
}

/// Real user input that went to one app: key presses, clicks, scrolls, and
/// gestures, whether or not any session leases the app.
public struct AppInputStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    public var lastInputMsAgo: Int

    public init(pid: Int32, lastInputMsAgo: Int) {
        self.pid = pid
        self.lastInputMsAgo = lastInputMsAgo
    }
}

/// What the focus guard on one target did during its current lease.
public struct GuardRestoreStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    /// How many times the guard put the previous app back during this lease.
    public var restoreCount: Int
    /// Milliseconds since the last restore. Absent when it has not restored.
    public var lastRestoreMsAgo: Int?

    public init(pid: Int32, restoreCount: Int, lastRestoreMsAgo: Int?) {
        self.pid = pid
        self.restoreCount = restoreCount
        self.lastRestoreMsAgo = lastRestoreMsAgo
    }
}

public struct PresenceStatus: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverPID: Int32
    public var aborted: Bool
    /// False when the listen-only event tap could not be created, usually
    /// because Accessibility or Input Monitoring is not granted. `userActive`
    /// and the abort key do not work without it.
    public var tapAvailable: Bool
    /// Window numbers of every cursor window, for excluding from display captures.
    public var overlayWindowIDs: [UInt32]
    public var sessions: [SessionStatus]
    /// Target pids with an active focus guard.
    public var guardedPIDs: [Int32]
    /// Restores per active guard. Absent from servers built before this field
    /// existed, which clients treat as "unknown".
    public var guardRestores: [GuardRestoreStatus]?
    /// Whether the process holds its display-awake assertion right now. Absent when
    /// keep-awake is off or the server predates this field.
    public var keepAwake: Bool?
    /// Milliseconds since the last real input of any kind (keys, modifiers,
    /// clicks, pointer motion, scrolls, gestures) from anyone but a client.
    /// Absent when none was seen.
    public var lastUserInputMsAgo: Int?
    /// Recent deliberate user input per app, newest first, bounded in count and age.
    public var appInput: [AppInputStatus]?

    public init(
        protocolVersion: Int,
        serverPID: Int32,
        aborted: Bool,
        tapAvailable: Bool,
        overlayWindowIDs: [UInt32],
        sessions: [SessionStatus],
        guardedPIDs: [Int32],
        guardRestores: [GuardRestoreStatus]? = nil,
        keepAwake: Bool? = nil,
        lastUserInputMsAgo: Int? = nil,
        appInput: [AppInputStatus]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.serverPID = serverPID
        self.aborted = aborted
        self.tapAvailable = tapAvailable
        self.overlayWindowIDs = overlayWindowIDs
        self.sessions = sessions
        self.guardedPIDs = guardedPIDs
        self.guardRestores = guardRestores
        self.keepAwake = keepAwake
        self.lastUserInputMsAgo = lastUserInputMsAgo
        self.appInput = appInput
    }

    public func session(_ id: String) -> SessionStatus? {
        sessions.first { $0.id == id }
    }

    /// Milliseconds since real user input reached `pid`, when any is recorded.
    public func inputMsAgo(pid: Int32) -> Int? {
        appInput?.first { $0.pid == pid }?.lastInputMsAgo
    }
}

// MARK: - Envelopes

public enum PresenceRequest: Equatable, Sendable {
    case hello(HelloParams)
    case sessionAcquire(SessionAcquireParams)
    case sessionRelease(SessionReleaseParams)
    case cursorMoveTo(CursorMoveParams)
    case cursorPress(CursorPressParams)
    case cursorSetState(CursorSetStateParams)
    case cursorHide(CursorHideParams)
    case guardBegin(GuardBeginParams)
    case guardEnd(GuardEndParams)
    case status
    case resume
    case shutdown

    public var method: PresenceMethod {
        switch self {
        case .hello: return .hello
        case .sessionAcquire: return .sessionAcquire
        case .sessionRelease: return .sessionRelease
        case .cursorMoveTo: return .cursorMoveTo
        case .cursorPress: return .cursorPress
        case .cursorSetState: return .cursorSetState
        case .cursorHide: return .cursorHide
        case .guardBegin: return .guardBegin
        case .guardEnd: return .guardEnd
        case .status: return .status
        case .resume: return .resume
        case .shutdown: return .shutdown
        }
    }
}

/// One request line.
public struct PresenceRequestEnvelope: Codable, Equatable, Sendable {
    public var id: UInt64
    public var request: PresenceRequest

    public init(id: UInt64, request: PresenceRequest) {
        self.id = id
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case id, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        let methodName = try container.decode(String.self, forKey: .method)
        guard let method = PresenceMethod(rawValue: methodName) else {
            throw DecodingError.dataCorruptedError(forKey: .method, in: container, debugDescription: "Unknown method \(methodName)")
        }
        switch method {
        case .hello: request = .hello(try container.decode(HelloParams.self, forKey: .params))
        case .sessionAcquire: request = .sessionAcquire(try container.decode(SessionAcquireParams.self, forKey: .params))
        case .sessionRelease: request = .sessionRelease(try container.decode(SessionReleaseParams.self, forKey: .params))
        case .cursorMoveTo: request = .cursorMoveTo(try container.decode(CursorMoveParams.self, forKey: .params))
        case .cursorPress: request = .cursorPress(try container.decode(CursorPressParams.self, forKey: .params))
        case .cursorSetState: request = .cursorSetState(try container.decode(CursorSetStateParams.self, forKey: .params))
        case .cursorHide: request = .cursorHide(try container.decode(CursorHideParams.self, forKey: .params))
        case .guardBegin: request = .guardBegin(try container.decode(GuardBeginParams.self, forKey: .params))
        case .guardEnd: request = .guardEnd(try container.decode(GuardEndParams.self, forKey: .params))
        case .status: request = .status
        case .resume: request = .resume
        case .shutdown: request = .shutdown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(request.method.rawValue, forKey: .method)
        switch request {
        case .hello(let params): try container.encode(params, forKey: .params)
        case .sessionAcquire(let params): try container.encode(params, forKey: .params)
        case .sessionRelease(let params): try container.encode(params, forKey: .params)
        case .cursorMoveTo(let params): try container.encode(params, forKey: .params)
        case .cursorPress(let params): try container.encode(params, forKey: .params)
        case .cursorSetState(let params): try container.encode(params, forKey: .params)
        case .cursorHide(let params): try container.encode(params, forKey: .params)
        case .guardBegin(let params): try container.encode(params, forKey: .params)
        case .guardEnd(let params): try container.encode(params, forKey: .params)
        case .status, .resume, .shutdown: break
        }
    }
}

/// Success payloads, one case per result shape.
public enum PresenceResult: Equatable, Sendable {
    case empty
    case hello(HelloResult)
    case lease(LeaseResult)
    case cursorMove(CursorMoveResult)
    case guardLease(GuardResult)
    case status(PresenceStatus)

    func encode(into container: inout KeyedEncodingContainer<PresenceResponse.CodingKeys>) throws {
        switch self {
        case .empty: try container.encode(PresenceEmpty(), forKey: .result)
        case .hello(let value): try container.encode(value, forKey: .result)
        case .lease(let value): try container.encode(value, forKey: .result)
        case .cursorMove(let value): try container.encode(value, forKey: .result)
        case .guardLease(let value): try container.encode(value, forKey: .result)
        case .status(let value): try container.encode(value, forKey: .result)
        }
    }

    static func decode(for method: PresenceMethod, from container: KeyedDecodingContainer<PresenceResponse.CodingKeys>) throws -> PresenceResult {
        switch method {
        case .hello:
            return .hello(try container.decode(HelloResult.self, forKey: .result))
        case .sessionAcquire:
            return .lease(try container.decode(LeaseResult.self, forKey: .result))
        case .cursorMoveTo:
            return .cursorMove(try container.decode(CursorMoveResult.self, forKey: .result))
        case .guardBegin:
            return .guardLease(try container.decode(GuardResult.self, forKey: .result))
        case .status:
            return .status(try container.decode(PresenceStatus.self, forKey: .result))
        case .sessionRelease, .cursorPress, .cursorSetState, .cursorHide, .guardEnd, .resume, .shutdown:
            return .empty
        }
    }
}

/// One response line. Decoding needs the request's method because result
/// shapes differ per method.
public struct PresenceResponse: Equatable, Sendable {
    public var id: UInt64
    public var outcome: Result<PresenceResult, PresenceError>

    public init(id: UInt64, outcome: Result<PresenceResult, PresenceError>) {
        self.id = id
        self.outcome = outcome
    }

    public static func success(id: UInt64, _ result: PresenceResult) -> PresenceResponse {
        PresenceResponse(id: id, outcome: .success(result))
    }

    public static func failure(id: UInt64, _ code: PresenceErrorCode, _ message: String) -> PresenceResponse {
        PresenceResponse(id: id, outcome: .failure(PresenceError(code: code, message: message)))
    }

    enum CodingKeys: String, CodingKey {
        case id, ok, result, error
    }

    public func encodeLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(EncodingBox(response: self))
        data.append(0x0A)
        return data
    }

    /// Reads only the id, so a client can route a line before it knows the method.
    public static func peekID(in data: Data) -> UInt64? {
        struct IDOnly: Decodable { let id: UInt64 }
        return try? JSONDecoder().decode(IDOnly.self, from: data).id
    }

    public static func decode(_ data: Data, method: PresenceMethod) throws -> PresenceResponse {
        let decoder = JSONDecoder()
        decoder.userInfo[PresenceResponse.methodUserInfoKey] = method
        return try decoder.decode(DecodingBox.self, from: data).response
    }

    static let methodUserInfoKey = CodingUserInfoKey(rawValue: "presenceMethod")!

    private struct EncodingBox: Encodable {
        let response: PresenceResponse

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(response.id, forKey: .id)
            switch response.outcome {
            case .success(let result):
                try container.encode(true, forKey: .ok)
                try result.encode(into: &container)
            case .failure(let error):
                try container.encode(false, forKey: .ok)
                try container.encode(error, forKey: .error)
            }
        }
    }

    private struct DecodingBox: Decodable {
        let response: PresenceResponse

        init(from decoder: Decoder) throws {
            guard let method = decoder.userInfo[PresenceResponse.methodUserInfoKey] as? PresenceMethod else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing method for response decoding"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(UInt64.self, forKey: .id)
            if try container.decode(Bool.self, forKey: .ok) {
                response = PresenceResponse(id: id, outcome: .success(try PresenceResult.decode(for: method, from: container)))
            } else {
                response = PresenceResponse(id: id, outcome: .failure(try container.decode(PresenceError.self, forKey: .error)))
            }
        }
    }
}

extension PresenceRequestEnvelope {
    public func encodeLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
