import Foundation
import ScreenCommanderPresence

/// `presence` on action results: what the presence process did for the action.
///
/// - `active`: presence took part: the abort check and the wait for the user ran,
///   and the session held the lease on the target when the action has one.
/// - `unavailable`: the presence process could not be reached; input was delivered without it.
/// - `disabled`: presence is turned off (`SCREENCOMMANDER_PRESENCE=0`).
enum ActionPresence: String, Codable, Sendable {
    case active
    case unavailable
    case disabled
}

/// Engine-wide presence defaults, resolved once per process.
struct PresenceSettings: Equatable, Sendable {
    /// Session ID used when a request does not name one.
    var defaultSession: String
    /// Whether actions draw the agent cursor unless a request says otherwise.
    var cursorEnabled: Bool

    static let defaultSessionID = "default"

    /// Session ID precedence: `--session` (per request), then `SCREENCOMMANDER_SESSION`,
    /// then a per-process ID when running `serve`, then `default`.
    /// `SCREENCOMMANDER_AGENT_CURSOR=0` turns the cursor off.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        serveProcessID: Int32? = nil
    ) -> PresenceSettings {
        let session: String
        if let fromEnvironment = environment["SCREENCOMMANDER_SESSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnvironment.isEmpty {
            session = fromEnvironment
        } else if let serveProcessID {
            session = "serve-\(serveProcessID)"
        } else {
            session = defaultSessionID
        }
        return PresenceSettings(
            defaultSession: session,
            cursorEnabled: !isOff(environment["SCREENCOMMANDER_AGENT_CURSOR"])
        )
    }

    /// `SCREENCOMMANDER_PRESENCE=0` turns presence off entirely: no cursor, leases,
    /// focus guard, or yield.
    static func presenceEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !isOff(environment["SCREENCOMMANDER_PRESENCE"])
    }

    private static func isOff(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["0", "false", "off", "no"].contains(value)
    }
}

/// Timing knobs for the presence flow. Tests shrink them and replace `sleep`.
struct PresencePolicy {
    static let defaultLeaseIdleMs = 15_000
    static let defaultCursorLingerMs = 10_000

    /// A lease is released once the session has not acted on its app for this
    /// long, whether the client is a one-shot CLI command or `serve`.
    var leaseIdleMs: Int = PresencePolicy.defaultLeaseIdleMs
    /// The agent cursor stays this long after the session's last action, then fades.
    var cursorLingerMs: Int = PresencePolicy.defaultCursorLingerMs
    /// Whether a lease outlives this process's connection to presence. A one-shot
    /// CLI command exits after each action, so its lease must outlast it until it
    /// goes idle. `serve` stays connected, so its leases end the moment it exits.
    var holdAfterDisconnect = true
    /// Focus-guard lease after each background action.
    var guardLeaseMs: Int = 3_000
    /// Total time to wait for the user to go quiet before `user_interrupted`.
    var userYieldTimeout: TimeInterval = 5
    /// Longest single wait between status checks while the user is active.
    var userYieldCheckInterval: TimeInterval = 1
    /// The presence process's quiet period; a session stops being `userActive`
    /// this long after the last real input.
    var userQuietPeriod: TimeInterval = 1
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// `holdMs` for `session.acquire`.
    var leaseHoldMs: Int {
        holdAfterDisconnect ? leaseIdleMs : 0
    }

    /// While one delivery runs longer than this, its lease is renewed this often
    /// so it cannot go idle mid-action.
    var leaseRenewInterval: TimeInterval {
        Double(leaseIdleMs) / 3000
    }

    /// `SCREENCOMMANDER_LEASE_IDLE_MS` and `SCREENCOMMANDER_CURSOR_LINGER_MS`
    /// override the lease idle period and the cursor linger. `serve` drops its
    /// leases when it exits.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, serve: Bool) -> PresencePolicy {
        var policy = PresencePolicy()
        policy.leaseIdleMs = milliseconds(environment["SCREENCOMMANDER_LEASE_IDLE_MS"], range: 500...600_000) ?? defaultLeaseIdleMs
        policy.cursorLingerMs = milliseconds(environment["SCREENCOMMANDER_CURSOR_LINGER_MS"], range: 0...120_000) ?? defaultCursorLingerMs
        policy.holdAfterDisconnect = !serve
        return policy
    }

    private static func milliseconds(_ value: String?, range: ClosedRange<Int>) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), let number = Int(text) else {
            return nil
        }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}

/// The engine's view of the presence process. Every call degrades to
/// `.unavailable` instead of throwing.
protocol PresenceControlling: AnyObject, Sendable {
    /// False for the disabled controller: the engine skips presence and reports `disabled`.
    var isEnabled: Bool { get }
    func acquire(session: String, pid: pid_t, holdMs: Int, idleMs: Int, lingerMs: Int) async -> PresenceReply<LeaseResult>
    func status() async -> PresenceReply<PresenceStatus>
    /// Status from a presence process that is already running, without starting
    /// one. Connecting registers this process, so input it posts next is not
    /// taken for the user's.
    func statusIfRunning() async -> PresenceReply<PresenceStatus>
    func setCursorState(session: String, state: CursorState) async -> PresenceReply<PresenceEmpty>
    func moveCursor(session: String, to point: PresencePoint, windowID: UInt32?) async -> PresenceReply<CursorMoveResult>
    func pressCursor(session: String, count: Int) async -> PresenceReply<PresenceEmpty>
    func beginGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult>
    func renewGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult>
    func beginLaunchGuard(pid: pid_t, leaseMs: Int, session: String, previousFrontmostPID: pid_t?) async -> PresenceReply<GuardResult>
    /// Ends the focus guard on `pid` before screencommander itself activates it
    /// (`focus`, `--foreground`), so the guard does not undo that activation.
    /// Never starts the presence process.
    func endGuard(pid: pid_t) async
    /// Closes this process's connection: leases taken without a hold (`serve`)
    /// end at once, and so do sessions left without a lease.
    func disconnect()
}

extension PresenceControlling {
    func renewGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> {
        await beginGuard(pid: pid, leaseMs: leaseMs, session: session)
    }

    func beginLaunchGuard(pid: pid_t, leaseMs: Int, session: String, previousFrontmostPID: pid_t?) async -> PresenceReply<GuardResult> {
        await beginGuard(pid: pid, leaseMs: leaseMs, session: session)
    }
}

/// Backed by `PresenceClient`, which starts the presence process on first use.
final class LivePresenceController: PresenceControlling, @unchecked Sendable {
    private let client: PresenceClient
    private let startErrorURL: URL?

    private let socketPath: String?

    init(client: PresenceClient, startErrorURL: URL? = nil, socketPath: String? = nil) {
        self.client = client
        self.startErrorURL = startErrorURL
        self.socketPath = socketPath
    }

    convenience init(socketPath: String, clientName: String, startErrorURL: URL? = nil) {
        var configuration = PresenceClientConfiguration(
            socketPath: socketPath,
            launch: PresenceLaunch.configuration(socketPath: socketPath),
            clientName: clientName
        )
        configuration.spawnTimeout = 3
        self.init(client: PresenceClient(configuration: configuration), startErrorURL: startErrorURL, socketPath: socketPath)
    }

    let isEnabled = true

    func acquire(session: String, pid: pid_t, holdMs: Int, idleMs: Int, lingerMs: Int) async -> PresenceReply<LeaseResult> {
        let reply = await client.acquire(session: session, pid: pid, holdMs: holdMs, idleMs: idleMs, lingerMs: lingerMs)
        if case .unavailable(let reason) = reply, let startErrorURL {
            // The presence process records its own, more specific, failure; keep it.
            PresenceLaunch.recordStartError(reason, at: startErrorURL, overwrite: false)
        }
        return reply
    }

    func status() async -> PresenceReply<PresenceStatus> {
        await client.status()
    }

    func statusIfRunning() async -> PresenceReply<PresenceStatus> {
        await client.statusIfRunning()
    }

    func disconnect() {
        client.disconnect()
    }

    func setCursorState(session: String, state: CursorState) async -> PresenceReply<PresenceEmpty> {
        await client.setCursorState(session: session, state: state)
    }

    func moveCursor(session: String, to point: PresencePoint, windowID: UInt32?) async -> PresenceReply<CursorMoveResult> {
        await client.moveCursor(session: session, to: point, windowID: windowID)
    }

    func pressCursor(session: String, count: Int) async -> PresenceReply<PresenceEmpty> {
        await client.pressCursor(session: session, count: count)
    }

    func beginGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> {
        await client.beginGuard(pid: pid, leaseMs: leaseMs, session: session)
    }

    func renewGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> {
        await client.renewGuard(pid: pid, leaseMs: leaseMs, session: session)
    }

    func beginLaunchGuard(pid: pid_t, leaseMs: Int, session: String, previousFrontmostPID: pid_t?) async -> PresenceReply<GuardResult> {
        await client.beginLaunchGuard(pid: pid, leaseMs: leaseMs, session: session, previousFrontmostPID: previousFrontmostPID)
    }

    func endGuard(pid: pid_t) async {
        // A probe never spawns: with no presence process there is no guard to end.
        guard let socketPath, FileManager.default.fileExists(atPath: socketPath),
              let probe = PresenceLaunch.probeClient(socketPath: socketPath, clientName: "screencommander activate") else {
            return
        }
        _ = await probe.endGuard(pid: pid)
        probe.disconnect()
    }
}

/// Presence turned off. The engine never calls the methods; they answer
/// `.unavailable` for completeness.
final class DisabledPresenceController: PresenceControlling, @unchecked Sendable {
    let isEnabled = false

    func acquire(session: String, pid: pid_t, holdMs: Int, idleMs: Int, lingerMs: Int) async -> PresenceReply<LeaseResult> { .unavailable(Self.reason) }
    func status() async -> PresenceReply<PresenceStatus> { .unavailable(Self.reason) }
    func statusIfRunning() async -> PresenceReply<PresenceStatus> { .unavailable(Self.reason) }
    func disconnect() {}
    func setCursorState(session: String, state: CursorState) async -> PresenceReply<PresenceEmpty> { .unavailable(Self.reason) }
    func moveCursor(session: String, to point: PresencePoint, windowID: UInt32?) async -> PresenceReply<CursorMoveResult> { .unavailable(Self.reason) }
    func pressCursor(session: String, count: Int) async -> PresenceReply<PresenceEmpty> { .unavailable(Self.reason) }
    func beginGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> { .unavailable(Self.reason) }
    func endGuard(pid: pid_t) async {}

    private static let reason = "Presence is disabled."
}

/// Presence is on but cannot be used, such as when the fallback socket directory
/// belongs to another user. Actions run without it and report `unavailable`.
final class UnavailablePresenceController: PresenceControlling, @unchecked Sendable {
    let isEnabled = true
    let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func acquire(session: String, pid: pid_t, holdMs: Int, idleMs: Int, lingerMs: Int) async -> PresenceReply<LeaseResult> { .unavailable(reason) }
    func status() async -> PresenceReply<PresenceStatus> { .unavailable(reason) }
    func statusIfRunning() async -> PresenceReply<PresenceStatus> { .unavailable(reason) }
    func disconnect() {}
    func setCursorState(session: String, state: CursorState) async -> PresenceReply<PresenceEmpty> { .unavailable(reason) }
    func moveCursor(session: String, to point: PresencePoint, windowID: UInt32?) async -> PresenceReply<CursorMoveResult> { .unavailable(reason) }
    func pressCursor(session: String, count: Int) async -> PresenceReply<PresenceEmpty> { .unavailable(reason) }
    func beginGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> { .unavailable(reason) }
    func endGuard(pid: pid_t) async {}
}

/// How the CLI finds and starts the presence process.
enum PresenceLaunch {
    static let subcommand = "presence"

    static func socketPath(statePaths: StatePaths) -> String {
        statePaths.presenceSocketURL.path
    }

    /// The running executable with the hidden `presence` subcommand.
    static func configuration(socketPath: String) -> PresenceLaunchConfiguration? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        return PresenceLaunchConfiguration(
            executableURL: executable,
            arguments: [subcommand, "--socket", socketPath]
        )
    }

    /// The engine's controller: live unless `SCREENCOMMANDER_PRESENCE=0`.
    static func controller(
        statePaths: StatePaths,
        clientName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PresenceControlling {
        guard PresenceSettings.presenceEnabled(environment: environment) else {
            return DisabledPresenceController()
        }
        let path = socketPath(statePaths: statePaths)
        if let problem = socketDirectoryProblem(socketPath: path, create: true) {
            recordStartError(problem, at: statePaths.presenceStartErrorURL, overwrite: true)
            return UnavailablePresenceController(reason: problem)
        }
        return LivePresenceController(socketPath: path, clientName: clientName, startErrorURL: statePaths.presenceStartErrorURL)
    }

    /// Checks the fallback socket directory in the shared temporary root: it must be
    /// a real directory owned by this user with no group or other access. With
    /// `create`, makes it (mode 0700) when missing and tightens its mode. Returns
    /// nil when the socket can be used, and nil for any socket outside the fallback
    /// directory, whose parent the presence process creates itself.
    static func socketDirectoryProblem(
        socketPath: String,
        create: Bool,
        fallbackDirectory: String = StatePaths.presenceFallbackDirectory()
    ) -> String? {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard directory == fallbackDirectory else {
            return nil
        }
        if create, mkdir(directory, 0o700) != 0, errno != EEXIST {
            return "Could not create the presence socket directory \(directory): \(String(cString: strerror(errno)))."
        }
        var info = stat()
        guard lstat(directory, &info) == 0 else {
            if !create, errno == ENOENT {
                return nil
            }
            return "Could not inspect the presence socket directory \(directory): \(String(cString: strerror(errno)))."
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return "The presence socket directory \(directory) is not a directory."
        }
        guard info.st_uid == getuid() else {
            return "The presence socket directory \(directory) belongs to uid \(info.st_uid), not \(getuid()). Remove it, or set SCREENCOMMANDER_STATE_DIR to a shorter path."
        }
        if info.st_mode & 0o077 != 0 {
            guard create, chmod(directory, 0o700) == 0 else {
                return "The presence socket directory \(directory) is readable by other users (mode \(String(info.st_mode & 0o777, radix: 8)))."
            }
        }
        return nil
    }

    /// Writes why presence could not start, for `doctor`. Without `overwrite`, an
    /// existing record is kept.
    static func recordStartError(_ reason: String, at url: URL, overwrite: Bool) {
        let fileManager = FileManager.default
        if !overwrite, fileManager.fileExists(atPath: url.path) {
            return
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((reason + "\n").utf8).write(to: url, options: .atomic)
    }

    static func clearStartError(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func readStartError(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// A client that talks to a running presence process and never starts one,
    /// for `doctor`, `resume`, and capture exclusion. Returns nil when the socket's
    /// directory fails `socketDirectoryProblem`, so these paths never connect to a
    /// socket in a directory another user controls.
    static func probeClient(
        socketPath: String,
        clientName: String,
        fallbackDirectory: String = StatePaths.presenceFallbackDirectory()
    ) -> PresenceClient? {
        guard socketDirectoryProblem(socketPath: socketPath, create: false, fallbackDirectory: fallbackDirectory) == nil else {
            return nil
        }
        var configuration = PresenceClientConfiguration(socketPath: socketPath, clientName: clientName)
        configuration.requestTimeout = 0.5
        return PresenceClient(configuration: configuration)
    }
}

/// Serializes input per target pid, so concurrent `serve` tool calls cannot
/// interleave events into one app. Different pids run in parallel.
/// `globalKey` stands for the HID event tap, which every app shares: a
/// foreground action holds it and its target's pid key, so it never runs
/// alongside another foreground action or alongside background delivery to the
/// same app.
actor InputSerializer {
    static let globalKey: pid_t = -1

    private var held: Set<pid_t> = []
    private var waiters: [pid_t: [CheckedContinuation<Void, Never>]] = [:]

    /// The keys an action holds, in the order to take them. Every caller takes
    /// the global key first, so two actions never wait on each other in a cycle.
    static func keys(pid: pid_t?, global: Bool) -> [pid_t] {
        var keys: [pid_t] = global || pid == nil ? [globalKey] : []
        if let pid, pid != globalKey {
            keys.append(pid)
        }
        return keys
    }

    func acquire(_ keys: [pid_t]) async {
        for key in keys {
            await acquire(key)
        }
    }

    func release(_ keys: [pid_t]) {
        for key in keys.reversed() {
            release(key)
        }
    }

    func acquire(_ key: pid_t) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    /// Hands the key straight to the next waiter, so it stays held.
    func release(_ key: pid_t) {
        guard var queue = waiters[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
