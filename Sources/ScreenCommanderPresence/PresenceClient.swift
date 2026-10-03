import Darwin
import Foundation

/// The outcome of one presence call. Nothing here throws: a missing or
/// unresponsive presence process is `.unavailable`, and callers carry on
/// without the cursor and report `presence: "unavailable"`.
public enum PresenceReply<Value> {
    case success(Value)
    /// The server answered with an error, such as `target_busy`.
    case failure(PresenceError)
    /// No server, a timeout, or a reply that could not be read.
    case unavailable(String)

    public var value: Value? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }

    public var error: PresenceError? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }

    public var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }

    func map<T>(_ transform: (Value) -> T?) -> PresenceReply<T> {
        switch self {
        case .success(let value):
            guard let mapped = transform(value) else {
                return .unavailable("Unexpected result shape from the presence process.")
            }
            return .success(mapped)
        case .failure(let error):
            return .failure(error)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}

extension PresenceReply: Sendable where Value: Sendable {}

/// How to start the presence process when nothing is listening.
public struct PresenceLaunchConfiguration: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    /// Environment for the child. Nil inherits the client's.
    public var environment: [String: String]?

    public init(executableURL: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

public struct PresenceClientConfiguration: Sendable {
    public var socketPath: String
    /// Nil means connect only and never spawn.
    public var launch: PresenceLaunchConfiguration?
    public var clientName: String?
    /// Timeout for every call except `cursor.moveTo`.
    public var requestTimeout: TimeInterval = 0.75
    /// Timeout for `cursor.moveTo`, which replies when the cursor arrives.
    public var moveTimeout: TimeInterval = 3.5
    /// How long to wait for a freshly spawned server to start listening.
    public var spawnTimeout: TimeInterval = 2
    /// After a spawn that never came up, wait this long before trying again.
    public var spawnRetryInterval: TimeInterval = 10

    public init(socketPath: String, launch: PresenceLaunchConfiguration? = nil, clientName: String? = nil) {
        self.socketPath = socketPath
        self.launch = launch
        self.clientName = clientName
    }
}

/// Client for the presence process. Thread-safe. One connection is shared by
/// all callers, and replies are matched to requests by id, so concurrent MCP
/// tool calls do not queue behind a slow `cursor.moveTo`. Every method comes
/// in a blocking form for the CLI and an `async` form for `serve`.
///
/// A lease ends once its session has not acted on the target for the lease's
/// idle period. A lease taken without `holdMs` also ends as soon as the client
/// calls `disconnect()`, deinitializes, or its process exits.
public final class PresenceClient: @unchecked Sendable {
    public let configuration: PresenceClientConfiguration

    private let connectLock = NSLock()
    private var connection: ClientConnection?
    private var lastSpawnFailure: Date?
    private var serverHello: HelloResult?

    public init(configuration: PresenceClientConfiguration) {
        self.configuration = configuration
    }

    deinit {
        connection?.close()
    }

    /// The server's `hello` reply on the current connection.
    public var hello: HelloResult? {
        connectLock.lock()
        defer { connectLock.unlock() }
        return connection?.isOpen == true ? serverHello : nil
    }

    /// Connects, spawning the server if configured, and performs `hello`.
    @discardableResult
    public func connect() -> PresenceReply<HelloResult> {
        switch establish(allowSpawn: true) {
        case .success(let pair): return .success(pair.1)
        case .failure(let reason): return .unavailable(reason.message)
        }
    }

    public func disconnect() {
        connectLock.lock()
        let current = connection
        connection = nil
        serverHello = nil
        connectLock.unlock()
        current?.close()
    }

    // MARK: Generic calls

    /// - Parameter allowSpawn: false only talks to a presence process that is
    ///   already running, and never starts one.
    public func send(_ request: PresenceRequest, timeout: TimeInterval? = nil, allowSpawn: Bool = true) -> PresenceReply<PresenceResult> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        perform(request, timeout: timeout, allowSpawn: allowSpawn) { reply in
            box.reply = reply
            semaphore.signal()
        }
        semaphore.wait()
        return box.reply ?? .unavailable("No reply.")
    }

    public func send(_ request: PresenceRequest, timeout: TimeInterval? = nil, allowSpawn: Bool = true) async -> PresenceReply<PresenceResult> {
        await withCheckedContinuation { continuation in
            // Connecting can block on a spawn, so keep it off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                self.perform(request, timeout: timeout, allowSpawn: allowSpawn) { reply in
                    continuation.resume(returning: reply)
                }
            }
        }
    }

    // MARK: Typed calls

    public func acquire(session: String, pid: Int32, holdMs: Int? = nil, idleMs: Int? = nil, lingerMs: Int? = nil) -> PresenceReply<LeaseResult> {
        let params = SessionAcquireParams(session: session, pid: pid, holdMs: holdMs, idleMs: idleMs, lingerMs: lingerMs)
        return send(.sessionAcquire(params)).map(Self.lease)
    }

    public func acquire(session: String, pid: Int32, holdMs: Int? = nil, idleMs: Int? = nil, lingerMs: Int? = nil) async -> PresenceReply<LeaseResult> {
        let params = SessionAcquireParams(session: session, pid: pid, holdMs: holdMs, idleMs: idleMs, lingerMs: lingerMs)
        return await send(.sessionAcquire(params)).map(Self.lease)
    }

    public func release(session: String, pid: Int32? = nil) -> PresenceReply<PresenceEmpty> {
        send(.sessionRelease(SessionReleaseParams(session: session, pid: pid))).map(Self.empty)
    }

    public func release(session: String, pid: Int32? = nil) async -> PresenceReply<PresenceEmpty> {
        await send(.sessionRelease(SessionReleaseParams(session: session, pid: pid))).map(Self.empty)
    }

    public func moveCursor(
        session: String,
        to point: PresencePoint,
        windowID: UInt32? = nil,
        timing: CursorMoveTiming = .closeEnough,
        timeout: TimeInterval? = nil
    ) -> PresenceReply<CursorMoveResult> {
        let params = CursorMoveParams(session: session, point: point, windowID: windowID, timing: timing)
        return send(.cursorMoveTo(params), timeout: timeout).map(Self.move)
    }

    public func moveCursor(
        session: String,
        to point: PresencePoint,
        windowID: UInt32? = nil,
        timing: CursorMoveTiming = .closeEnough,
        timeout: TimeInterval? = nil
    ) async -> PresenceReply<CursorMoveResult> {
        let params = CursorMoveParams(session: session, point: point, windowID: windowID, timing: timing)
        return await send(.cursorMoveTo(params), timeout: timeout).map(Self.move)
    }

    public func pressCursor(session: String, count: Int = 1) -> PresenceReply<PresenceEmpty> {
        send(.cursorPress(CursorPressParams(session: session, count: count))).map(Self.empty)
    }

    public func pressCursor(session: String, count: Int = 1) async -> PresenceReply<PresenceEmpty> {
        await send(.cursorPress(CursorPressParams(session: session, count: count))).map(Self.empty)
    }

    public func setCursorState(session: String, state: CursorState) -> PresenceReply<PresenceEmpty> {
        send(.cursorSetState(CursorSetStateParams(session: session, state: state))).map(Self.empty)
    }

    public func setCursorState(session: String, state: CursorState) async -> PresenceReply<PresenceEmpty> {
        await send(.cursorSetState(CursorSetStateParams(session: session, state: state))).map(Self.empty)
    }

    public func hideCursor(session: String) -> PresenceReply<PresenceEmpty> {
        send(.cursorHide(CursorHideParams(session: session))).map(Self.empty)
    }

    public func hideCursor(session: String) async -> PresenceReply<PresenceEmpty> {
        await send(.cursorHide(CursorHideParams(session: session))).map(Self.empty)
    }

    public func beginGuard(pid: Int32, leaseMs: Int, session: String? = nil) -> PresenceReply<GuardResult> {
        send(.guardBegin(GuardBeginParams(pid: pid, leaseMs: leaseMs, session: session))).map(Self.guardLease)
    }

    public func beginGuard(pid: Int32, leaseMs: Int, session: String? = nil) async -> PresenceReply<GuardResult> {
        await send(.guardBegin(GuardBeginParams(pid: pid, leaseMs: leaseMs, session: session))).map(Self.guardLease)
    }

    public func endGuard(pid: Int32) -> PresenceReply<PresenceEmpty> {
        send(.guardEnd(GuardEndParams(pid: pid))).map(Self.empty)
    }

    public func renewGuard(pid: Int32, leaseMs: Int, session: String? = nil) async -> PresenceReply<GuardResult> {
        await send(.guardBegin(GuardBeginParams(pid: pid, leaseMs: leaseMs, session: session, renew: true))).map(Self.guardLease)
    }

    public func beginLaunchGuard(pid: Int32, leaseMs: Int, session: String? = nil, previousFrontmostPID: Int32?) async -> PresenceReply<GuardResult> {
        await send(.guardBegin(GuardBeginParams(pid: pid, leaseMs: leaseMs, session: session, previousFrontmostPID: previousFrontmostPID))).map(Self.guardLease)
    }

    public func endGuard(pid: Int32) async -> PresenceReply<PresenceEmpty> {
        await send(.guardEnd(GuardEndParams(pid: pid))).map(Self.empty)
    }

    public func status() -> PresenceReply<PresenceStatus> {
        send(.status).map(Self.status)
    }

    public func status() async -> PresenceReply<PresenceStatus> {
        await send(.status).map(Self.status)
    }

    /// Status from a presence process that is already running. Never starts one.
    /// Connecting registers this process as a client, so input it posts next is
    /// not taken for the user's.
    public func statusIfRunning() -> PresenceReply<PresenceStatus> {
        send(.status, allowSpawn: false).map(Self.status)
    }

    public func statusIfRunning() async -> PresenceReply<PresenceStatus> {
        await send(.status, allowSpawn: false).map(Self.status)
    }

    public func resume() -> PresenceReply<PresenceEmpty> {
        send(.resume).map(Self.empty)
    }

    public func resume() async -> PresenceReply<PresenceEmpty> {
        await send(.resume).map(Self.empty)
    }

    public func shutdown() -> PresenceReply<PresenceEmpty> {
        send(.shutdown).map(Self.empty)
    }

    public func shutdown() async -> PresenceReply<PresenceEmpty> {
        await send(.shutdown).map(Self.empty)
    }

    // MARK: Result extraction

    private static func empty(_ result: PresenceResult) -> PresenceEmpty? {
        if case .empty = result { return PresenceEmpty() }
        return nil
    }

    private static func lease(_ result: PresenceResult) -> LeaseResult? {
        if case .lease(let value) = result { return value }
        return nil
    }

    private static func move(_ result: PresenceResult) -> CursorMoveResult? {
        if case .cursorMove(let value) = result { return value }
        return nil
    }

    private static func guardLease(_ result: PresenceResult) -> GuardResult? {
        if case .guardLease(let value) = result { return value }
        return nil
    }

    private static func status(_ result: PresenceResult) -> PresenceStatus? {
        if case .status(let value) = result { return value }
        return nil
    }

    // MARK: Connection management

    private struct Unavailable: Error {
        let message: String
        /// The server speaks an older protocol and can be replaced.
        var olderServer = false
    }

    private final class ReplyBox: @unchecked Sendable {
        var reply: PresenceReply<PresenceResult>?
    }

    /// Sends on the shared connection. A presence process that exits between
    /// requests (it stops once nothing is active, even with clients connected)
    /// closes the connection, so a request that finds it gone is sent once more
    /// on a fresh one.
    private func perform(
        _ request: PresenceRequest,
        timeout: TimeInterval?,
        allowSpawn: Bool,
        retried: Bool = false,
        completion: @escaping (PresenceReply<PresenceResult>) -> Void
    ) {
        let resolvedTimeout = timeout ?? (request.method == .cursorMoveTo ? configuration.moveTimeout : configuration.requestTimeout)
        switch establish(allowSpawn: allowSpawn) {
        case .success(let pair):
            pair.0.send(request, timeout: resolvedTimeout) { [weak self] reply in
                guard let self, !retried, request.method != .shutdown, Self.lostConnection(reply) else {
                    completion(reply)
                    return
                }
                self.perform(request, timeout: timeout, allowSpawn: allowSpawn, retried: true, completion: completion)
            }
        case .failure(let reason):
            completion(.unavailable(reason.message))
        }
    }

    private static func lostConnection(_ reply: PresenceReply<PresenceResult>) -> Bool {
        switch reply {
        case .unavailable(let reason):
            return reason == ClientConnection.closedReason || reason == ClientConnection.alreadyClosedReason
        case .failure(let error):
            return error.code == .shuttingDown
        case .success:
            return false
        }
    }

    private func establish(allowSpawn: Bool) -> Result<(ClientConnection, HelloResult), Unavailable> {
        connectLock.lock()
        defer { connectLock.unlock() }

        if let connection, connection.isOpen, let serverHello {
            return .success((connection, serverHello))
        }
        connection?.close()
        connection = nil
        serverHello = nil

        var result = openAndGreet(allowSpawn: allowSpawn)
        if case .failure(let reason) = result, reason.olderServer, allowSpawn, configuration.launch != nil {
            // A presence process from an older build is running. Ask it to exit
            // and start a current one. A newer one is left alone.
            if case .success(let fd) = UnixSocket.connect(path: configuration.socketPath) {
                let stale = ClientConnection(fd: fd)
                stale.start()
                _ = stale.sendBlocking(.shutdown, timeout: configuration.requestTimeout)
                stale.close()
                waitForSocketRelease()
            }
            result = openAndGreet(allowSpawn: true)
        }
        if case .success(let pair) = result {
            connection = pair.0
            serverHello = pair.1
        }
        return result
    }

    private func openAndGreet(allowSpawn: Bool) -> Result<(ClientConnection, HelloResult), Unavailable> {
        let path = configuration.socketPath
        var fd: Int32?
        var lastError = ""

        switch UnixSocket.connect(path: path) {
        case .success(let value):
            fd = value
        case .failure(let error):
            lastError = error.description
        }

        if fd == nil, allowSpawn, let launch = configuration.launch {
            if let lastSpawnFailure, Date().timeIntervalSince(lastSpawnFailure) < configuration.spawnRetryInterval {
                return .failure(Unavailable(message: "Presence process did not start recently; not retrying yet. Last error: \(lastError)"))
            }
            if let spawnError = PresenceSpawner.spawnDetached(launch) {
                lastSpawnFailure = Date()
                return .failure(Unavailable(message: spawnError))
            }
            let deadline = Date().addingTimeInterval(configuration.spawnTimeout)
            while fd == nil, Date() < deadline {
                usleep(20_000)
                if case .success(let value) = UnixSocket.connect(path: path) {
                    fd = value
                }
            }
            if fd == nil {
                lastSpawnFailure = Date()
                lastError = "Presence process did not start listening within \(configuration.spawnTimeout)s."
            }
        }

        guard let fd else {
            return .failure(Unavailable(message: "Presence process unreachable at \(path): \(lastError)"))
        }

        let connection = ClientConnection(fd: fd)
        connection.start()
        let hello = HelloParams(pid: getpid(), client: configuration.clientName)
        switch connection.sendBlocking(.hello(hello), timeout: configuration.requestTimeout) {
        case .success(.hello(let result)) where result.protocolVersion == PresenceProtocol.version:
            return .success((connection, result))
        case .success(.hello(let result)):
            connection.close()
            let older = result.protocolVersion < PresenceProtocol.version
            return .failure(Unavailable(
                message: "Protocol version mismatch: server \(result.protocolVersion), client \(PresenceProtocol.version)."
                    + (older ? "" : " A newer presence process is running; this client leaves it alone."),
                olderServer: older
            ))
        case .failure(let error) where error.code == .unsupportedVersion:
            // Only servers before version 2 refuse a greeting. Later ones answer
            // with their own version.
            connection.close()
            return .failure(Unavailable(message: "Protocol version mismatch: \(error.message)", olderServer: true))
        case .failure(let error):
            connection.close()
            return .failure(Unavailable(message: "Presence hello failed: \(error.message)"))
        case .unavailable(let reason):
            connection.close()
            return .failure(Unavailable(message: "Presence hello failed: \(reason)"))
        case .success:
            connection.close()
            return .failure(Unavailable(message: "Presence hello returned an unexpected result."))
        }
    }

    private func waitForSocketRelease() {
        let deadline = Date().addingTimeInterval(configuration.spawnTimeout)
        while Date() < deadline {
            if case .failure = UnixSocket.connect(path: configuration.socketPath) {
                return
            }
            usleep(20_000)
        }
    }
}

/// One socket to the server with a reader thread that routes replies by id.
final class ClientConnection: @unchecked Sendable {
    typealias Completion = (PresenceReply<PresenceResult>) -> Void

    /// The reply for requests still pending when the server closes the connection.
    static let closedReason = "Presence process closed the connection."
    static let alreadyClosedReason = "Presence connection is closed."

    private let fd: Int32
    private let lock = NSLock()
    /// Serializes writes and keeps the reader from closing the fd mid-write.
    private let writeLock = NSLock()
    private var pending: [UInt64: (method: PresenceMethod, completion: Completion)] = [:]
    private var nextID: UInt64 = 1
    private var open = true

    init(fd: Int32) {
        self.fd = fd
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func start() {
        let thread = Thread { [self] in
            readLoop()
        }
        thread.name = "screencommander.presence.client"
        thread.start()
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let wasOpen = open
        open = false
        lock.unlock()
        if wasOpen {
            // Wakes the reader, which closes the descriptor on its way out.
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    func send(_ request: PresenceRequest, timeout: TimeInterval, completion: @escaping Completion) {
        lock.lock()
        guard open else {
            lock.unlock()
            completion(.unavailable(Self.alreadyClosedReason))
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = (request.method, completion)
        lock.unlock()

        guard let line = try? PresenceRequestEnvelope(id: id, request: request).encodeLine() else {
            resolve(id, with: .unavailable("Could not encode request."))
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(id, with: .unavailable("Presence call \(request.method.rawValue) timed out after \(timeout)s."))
        }

        writeLock.lock()
        let written = isOpen && UnixSocket.writeAll(fd, line, timeout: timeout)
        writeLock.unlock()
        if !written {
            resolve(id, with: .unavailable("Could not write to the presence process."))
            close()
        }
    }

    func sendBlocking(_ request: PresenceRequest, timeout: TimeInterval) -> PresenceReply<PresenceResult> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: PresenceReply<PresenceResult> = .unavailable("No reply.")
        send(request, timeout: timeout) { reply in
            result = reply
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func resolve(_ id: UInt64, with reply: PresenceReply<PresenceResult>) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        entry?.completion(reply)
    }

    private func readLoop() {
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        reading: while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0, let batch = lines.append(Data(buffer[0..<count])) else {
                break reading
            }
            for line in batch {
                route(line)
            }
        }

        lock.lock()
        open = false
        let orphans = pending
        pending.removeAll()
        lock.unlock()
        writeLock.lock()
        Darwin.close(fd)
        writeLock.unlock()
        for entry in orphans.values {
            entry.completion(.unavailable(Self.closedReason))
        }
    }

    private func route(_ line: Data) {
        guard let id = PresenceResponse.peekID(in: line) else {
            return
        }
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else {
            return
        }
        do {
            let response = try PresenceResponse.decode(line, method: entry.method)
            switch response.outcome {
            case .success(let result): entry.completion(.success(result))
            case .failure(let error): entry.completion(.failure(error))
            }
        } catch {
            entry.completion(.unavailable("Could not decode presence reply: \(error)"))
        }
    }
}

/// Starts the presence process so it outlives the client: its own session,
/// stdio on /dev/null, no inherited descriptors, and reaped in the background
/// if the client is still alive when it exits.
enum PresenceSpawner {
    /// Returns nil on success, or an error description.
    static func spawnDetached(_ launch: PresenceLaunchConfiguration) -> String? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let path = launch.executableURL.path
        let argv = ([path] + launch.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        let environment = launch.environment ?? ProcessInfo.processInfo.environment
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            return "Could not start \(path): \(String(cString: strerror(status)))"
        }
        reapWhenExited(pid)
        return nil
    }

    private static let reaperLock = NSLock()
    private static var reapers: [pid_t: DispatchSourceProcess] = [:]

    private static func reapWhenExited(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            reaperLock.lock()
            reapers.removeValue(forKey: pid)?.cancel()
            reaperLock.unlock()
        }
        reaperLock.lock()
        reapers[pid] = source
        reaperLock.unlock()
        source.resume()
    }
}
