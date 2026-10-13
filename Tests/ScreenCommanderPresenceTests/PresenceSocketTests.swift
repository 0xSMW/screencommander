import Darwin
import Foundation
import XCTest
@testable import ScreenCommanderPresence

/// Runs `PresenceSocketServer` + `PresenceCore` in-process, with no
/// NSApplication, and talks to it through `PresenceClient`.
final class PresenceSocketTests: XCTestCase {
    private final class RecordingDriver: PresenceCursorDriver, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        /// Delay before a move completes, to exercise out-of-order replies.
        var moveDelay: TimeInterval = 0

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        private func record(_ call: String) {
            lock.lock()
            _calls.append(call)
            lock.unlock()
        }

        func moveCursor(
            session: String,
            colorIndex: Int,
            state: CursorState,
            to point: PresencePoint,
            windowID: UInt32?,
            timing: CursorMoveTiming,
            completion: @escaping (CursorMoveOutcome) -> Void
        ) {
            record("move \(session) \(Int(point.x)),\(Int(point.y))")
            let outcome = CursorMoveOutcome(point: point, arrived: true, visible: true, cursorWindowID: 4242)
            if moveDelay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + moveDelay) { completion(outcome) }
            } else {
                completion(outcome)
            }
        }

        func pressCursor(session: String, count: Int) { record("press \(session) \(count)") }
        func setCursorState(session: String, state: CursorState) { record("state \(session) \(state.rawValue)") }
        func hideCursor(session: String) { record("hide \(session)") }
        func removeCursor(session: String) { record("remove \(session)") }
        func overlayWindowIDs() -> [UInt32] { [4242] }
    }

    private var socketPath: String!
    private var driver: RecordingDriver!
    private var core: PresenceCore!
    private var server: PresenceSocketServer!
    private var clients: [PresenceClient] = []

    override func setUpWithError() throws {
        socketPath = Self.makeSocketPath()
        driver = RecordingDriver()
        core = PresenceCore(driver: driver, environment: PresenceEnvironment(frontmostPID: { 77 }, tapAvailable: { true }))
        server = PresenceSocketServer(socketPath: socketPath, core: core)
        try server.start()
    }

    override func tearDown() {
        clients.forEach { $0.disconnect() }
        clients.removeAll()
        server?.stop()
        if let socketPath {
            unlink(socketPath + ".lock")
        }
    }

    private static func makeSocketPath() -> String {
        let name = "scp-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    private func makeClient(path: String? = nil, launch: PresenceLaunchConfiguration? = nil) -> PresenceClient {
        var configuration = PresenceClientConfiguration(socketPath: path ?? socketPath, launch: launch, clientName: "tests")
        configuration.requestTimeout = 2
        configuration.moveTimeout = 2
        let client = PresenceClient(configuration: configuration)
        clients.append(client)
        return client
    }

    // MARK: Round trips

    func testHelloAndStatusRoundTrip() throws {
        let client = makeClient()
        let hello = try XCTUnwrap(client.connect().value)
        XCTAssertEqual(hello.protocolVersion, PresenceProtocol.version)
        XCTAssertEqual(hello.serverPID, getpid())
        XCTAssertTrue(hello.tapAvailable)

        let status = try XCTUnwrap(client.status().value)
        XCTAssertFalse(status.aborted)
        XCTAssertEqual(status.overlayWindowIDs, [4242])
        XCTAssertTrue(status.sessions.isEmpty)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testLeasesAcrossClientsAndExpiryOnDisconnect() throws {
        let first = makeClient()
        let second = makeClient()

        let lease = try XCTUnwrap(first.acquire(session: "alpha", pid: getpid()).value)
        XCTAssertEqual(lease.session, "alpha")

        let busy = second.acquire(session: "beta", pid: getpid())
        XCTAssertEqual(busy.error?.code, .targetBusy)

        let status = try XCTUnwrap(second.status().value)
        XCTAssertEqual(status.session("alpha")?.pids, [getpid()])

        // The first client goes away; its lease goes with it.
        first.disconnect()
        let freed = expectation(description: "lease freed")
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if second.acquire(session: "beta", pid: getpid()).value != nil {
                    freed.fulfill()
                    return
                }
                usleep(20_000)
            }
        }
        wait(for: [freed], timeout: 5)
    }

    func testCursorCallsReachTheDriver() throws {
        let client = makeClient()
        let moved = try XCTUnwrap(client.moveCursor(session: "s", to: PresencePoint(x: 120, y: 340), windowID: 9).value)
        XCTAssertTrue(moved.arrived)
        XCTAssertEqual(moved.point, PresencePoint(x: 120, y: 340))
        XCTAssertEqual(moved.cursorWindowID, 4242)

        XCTAssertNotNil(client.pressCursor(session: "s", count: 2).value)
        XCTAssertNotNil(client.setCursorState(session: "s", state: .loading).value)
        XCTAssertNotNil(client.hideCursor(session: "s").value)
        XCTAssertNotNil(client.release(session: "s").value)

        XCTAssertEqual(driver.calls, [
            "move s 120,340",
            "press s 2",
            "state s loading",
            "hide s",
            "remove s"
        ])
    }

    func testAbortBlocksCursorUntilResume() throws {
        let client = makeClient()
        XCTAssertNotNil(client.acquire(session: "s", pid: getpid()).value)
        XCTAssertNotNil(client.setCursorState(session: "s", state: .loading).value)

        XCTAssertEqual(core.recordUserInput(sourcePID: 0, targetPID: nil, isAbortChord: true), .aborted)
        XCTAssertEqual(client.status().value?.aborted, true)
        XCTAssertEqual(client.status().value?.session("s")?.state, .paused)
        XCTAssertEqual(client.moveCursor(session: "s", to: PresencePoint(x: 1, y: 1)).error?.code, .abortedByUser)
        XCTAssertEqual(client.pressCursor(session: "s").error?.code, .abortedByUser)

        XCTAssertNotNil(client.resume().value)
        XCTAssertEqual(client.status().value?.aborted, false)
        XCTAssertEqual(client.status().value?.session("s")?.state, .loading)
        XCTAssertNotNil(client.moveCursor(session: "s", to: PresencePoint(x: 1, y: 1)).value)
        XCTAssertTrue(driver.calls.contains("state s paused"))
    }

    func testUserActivityIsReportedInStatus() throws {
        let client = makeClient()
        XCTAssertNotNil(client.acquire(session: "s", pid: getpid()).value)
        // Input from a registered client does not count as the user.
        XCTAssertEqual(core.recordUserInput(sourcePID: getpid(), targetPID: getpid(), isAbortChord: false), .ignored)
        XCTAssertEqual(client.status().value?.session("s")?.userActive, false)
        XCTAssertEqual(core.recordUserInput(sourcePID: 0, targetPID: getpid(), isAbortChord: false), .recorded(sessions: ["s"]))
        XCTAssertEqual(client.status().value?.session("s")?.userActive, true)
    }

    func testFocusGuardOverTheSocket() throws {
        let client = makeClient()
        let guardLease = try XCTUnwrap(client.beginGuard(pid: 900, leaseMs: 3000, session: "s").value)
        XCTAssertEqual(guardLease.previousFrontmostPID, 77)
        XCTAssertEqual(client.status().value?.guardedPIDs, [900])
        XCTAssertEqual(core.applicationActivated(pid: 900), .restore(77))
        XCTAssertNotNil(client.endGuard(pid: 900).value)
        XCTAssertEqual(core.applicationActivated(pid: 900), .ignore(.notGuarded))
    }

    func testRepliesAreMatchedByIDWhenOutOfOrder() async throws {
        driver.moveDelay = 0.4
        let client = makeClient()
        _ = client.connect()

        async let move = client.moveCursor(session: "s", to: PresencePoint(x: 5, y: 6))
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        let status = await client.status()
        XCTAssertNotNil(status.value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "status must not queue behind the pending move")
        let moved = await move
        XCTAssertEqual(moved.value?.point, PresencePoint(x: 5, y: 6))
    }

    func testMoveTimeoutIsUnavailableNotFatal() throws {
        driver.moveDelay = 1.0
        let client = makeClient()
        let reply = client.moveCursor(session: "s", to: PresencePoint(x: 1, y: 1), timeout: 0.1)
        XCTAssertTrue(reply.isUnavailable)
        // The connection survives a timed-out call.
        XCTAssertNotNil(client.status().value)
    }

    func testShutdownInvokesHandler() throws {
        let stopped = expectation(description: "shutdown")
        core.onShutdown = { stopped.fulfill() }
        let client = makeClient()
        XCTAssertNotNil(client.shutdown().value)
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(client.status().error?.code, .shuttingDown)
    }

    func testStatusReportsInputPerAppAndOverall() throws {
        let client = makeClient()
        core.recordUserInput(sourcePID: 0, targetPID: 4321, isAbortChord: false)
        let status = try XCTUnwrap(client.status().value)
        XCTAssertNotNil(status.inputMsAgo(pid: 4321), "input in an app no session leases is still reported")
        XCTAssertNotNil(status.lastUserInputMsAgo)
    }

    func testAnOlderClientCannotShutDownThisServer() throws {
        var stopped = false
        core.onShutdown = { stopped = true }
        let fd = try XCTUnwrap(UnixSocket.connect(path: socketPath).successValue)
        defer { close(fd) }
        // What a version 1 client does when it meets a newer server: greet, see the
        // mismatch, then send shutdown on a fresh connection without greeting.
        XCTAssertTrue(UnixSocket.writeAll(fd, Data(#"{"id":1,"method":"shutdown"}"#.utf8 + [0x0A]), timeout: 1))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let response = try PresenceResponse.decode(Data(buffer[0..<count]).dropLast(), method: .shutdown)
        guard case .failure(let error) = response.outcome else {
            return XCTFail("Expected a refusal")
        }
        XCTAssertEqual(error.code, .unsupportedVersion)
        XCTAssertFalse(stopped)
        XCTAssertNotNil(makeClient().status().value, "still serving")
    }

    func testAClientReplacesAnOlderServer() throws {
        // A stand-in for a presence process from an older build: it refuses any
        // greeting but its own version and stops on shutdown from anyone.
        server.stop()
        unlink(socketPath + ".lock")
        let path = socketPath!
        let old = OldServer(path: path)
        try old.start()
        defer { old.stop() }

        let stub = PresenceLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        )
        let client = makeClient(launch: stub)
        _ = client.connect()
        XCTAssertTrue(old.receivedShutdown, "the client asked the older server to stop")
    }

    func testAClientGreetsVersionTwoOnTheShutdownConnection() throws {
        server.stop()
        unlink(socketPath + ".lock")
        let old = OldServer(path: socketPath, version: 2, answersHello: true)
        try old.start()
        defer { old.stop() }
        let stub = PresenceLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"])
        _ = makeClient(launch: stub).connect()
        XCTAssertTrue(old.receivedShutdown, "v2 requires hello on the same connection before accepting shutdown")
    }

    func testAClientLeavesANewerServerAlone() throws {
        server.stop()
        unlink(socketPath + ".lock")
        let old = OldServer(path: socketPath, version: PresenceProtocol.version + 1, answersHello: true)
        try old.start()
        defer { old.stop() }

        let stub = PresenceLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"])
        let client = makeClient(launch: stub)
        XCTAssertTrue(client.connect().isUnavailable)
        XCTAssertFalse(old.receivedShutdown)
    }

    func testMalformedLineGetsAnErrorReply() throws {
        let fd = try XCTUnwrap(UnixSocket.connect(path: socketPath).successValue)
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.writeAll(fd, Data(#"{"id":9,"method":"cursor.teleport","params":{}}"#.utf8 + [0x0A]), timeout: 1))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let response = try PresenceResponse.decode(Data(buffer[0..<count]).dropLast(), method: .status)
        XCTAssertEqual(response.id, 9)
        guard case .failure(let error) = response.outcome else {
            return XCTFail("Expected an error")
        }
        XCTAssertEqual(error.code, .unknownMethod)
    }

    // MARK: Server lifecycle

    func testSecondServerOnLiveSocketIsRefused() {
        let rival = PresenceSocketServer(socketPath: socketPath, core: PresenceCore(driver: HeadlessCursorDriver()))
        XCTAssertThrowsError(try rival.start()) { error in
            XCTAssertEqual(error as? PresenceSocketError, .alreadyRunning(socketPath))
        }
        // The original keeps serving.
        XCTAssertNotNil(makeClient().status().value)
    }

    func testStaleSocketFromCrashedPredecessorIsReplaced() throws {
        let path = Self.makeSocketPath()
        defer {
            unlink(path)
            unlink(path + ".lock")
        }
        // Leave a bound socket file behind with nobody listening, as a crash would.
        let fd = try UnixSocket.makeSocket()
        try UnixSocket.bind(fd, path: path)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(makeClient(path: path).status().isUnavailable)

        let replacement = PresenceSocketServer(socketPath: path, core: PresenceCore(driver: HeadlessCursorDriver()))
        try replacement.start()
        defer { replacement.stop() }
        XCTAssertNotNil(makeClient(path: path).status().value)
    }

    func testStopRemovesSocketFile() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: Unavailable

    func testMissingServerIsUnavailableNotThrown() {
        let client = makeClient(path: Self.makeSocketPath())
        let started = Date()
        XCTAssertTrue(client.status().isUnavailable)
        XCTAssertTrue(client.connect().isUnavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSpawnThatNeverListensIsUnavailable() {
        var configuration = PresenceClientConfiguration(
            socketPath: Self.makeSocketPath(),
            launch: PresenceLaunchConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        )
        configuration.spawnTimeout = 0.2
        let client = PresenceClient(configuration: configuration)
        XCTAssertTrue(client.status().isUnavailable)
        // Within the retry interval the client does not spawn again.
        let started = Date()
        XCTAssertTrue(client.status().isUnavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15)
    }

    func testSpawnOfMissingExecutableIsUnavailable() {
        let client = makeClient(
            path: Self.makeSocketPath(),
            launch: PresenceLaunchConfiguration(executableURL: URL(fileURLWithPath: "/nonexistent/screencommander"), arguments: ["presence"])
        )
        XCTAssertTrue(client.status().isUnavailable)
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

/// A minimal presence server speaking another protocol version, for the
/// version handshake tests. Version 1 refused a mismatched greeting; later
/// versions answer it with their own version.
private final class OldServer: @unchecked Sendable {
    let path: String
    let version: Int
    let answersHello: Bool
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var shutdown = false
    private var running = true

    init(path: String, version: Int = 1, answersHello: Bool = false) {
        self.path = path
        self.version = version
        self.answersHello = answersHello
    }

    var receivedShutdown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutdown
    }

    func start() throws {
        unlink(path)
        let fd = try UnixSocket.makeSocket()
        try UnixSocket.bind(fd, path: path)
        guard listen(fd, 8) == 0 else {
            throw PresenceSocketError.systemCall("listen", errno)
        }
        listenFD = fd
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                return
            }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var greetedVersion = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int, let method = object["method"] as? String else {
                    continue
                }
                let reply: String
                switch method {
                case "hello" where answersHello:
                    greetedVersion = (object["params"] as? [String: Any])?["protocolVersion"] as? Int ?? 0
                    reply = #"{"id":\#(id),"ok":true,"result":{"protocolVersion":\#(version),"serverPID":1,"tapAvailable":true}}"#
                case "hello":
                    reply = #"{"id":\#(id),"ok":false,"error":{"code":"unsupported_version","message":"Server speaks protocol \#(version)."}}"#
                case "shutdown" where version >= 2 && greetedVersion < version:
                    reply = #"{"id":\#(id),"ok":false,"error":{"code":"unsupported_version","message":"Greeting required."}}"#
                case "shutdown":
                    lock.lock()
                    shutdown = true
                    lock.unlock()
                    reply = #"{"id":\#(id),"ok":true,"result":{}}"#
                    _ = UnixSocket.writeAll(fd, Data((reply + "\n").utf8), timeout: 1)
                    stop()
                    return
                default:
                    reply = #"{"id":\#(id),"ok":true,"result":{}}"#
                }
                _ = UnixSocket.writeAll(fd, Data((reply + "\n").utf8), timeout: 1)
            }
        }
    }
}
