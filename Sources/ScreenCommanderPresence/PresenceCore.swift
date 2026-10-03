import Foundation

/// How a cursor glide ended, reported by the driver.
public struct CursorMoveOutcome: Equatable, Sendable {
    public var point: PresencePoint
    public var arrived: Bool
    public var visible: Bool
    public var cursorWindowID: UInt32?

    public init(point: PresencePoint, arrived: Bool, visible: Bool, cursorWindowID: UInt32?) {
        self.point = point
        self.arrived = arrived
        self.visible = visible
        self.cursorWindowID = cursorWindowID
    }
}

/// Draws session cursors. The AppKit implementation is `CursorOverlayController`.
/// Calls arrive on the core's caller thread, so implementations hop to the
/// main thread themselves. `overlayWindowIDs()` must be safe from any thread.
public protocol PresenceCursorDriver: AnyObject {
    func moveCursor(
        session: String,
        colorIndex: Int,
        state: CursorState,
        to point: PresencePoint,
        windowID: UInt32?,
        timing: CursorMoveTiming,
        completion: @escaping (CursorMoveOutcome) -> Void
    )
    func pressCursor(session: String, count: Int)
    func setCursorState(session: String, state: CursorState)
    func hideCursor(session: String)
    func removeCursor(session: String)
    func overlayWindowIDs() -> [UInt32]
}

/// Driver for running without a window server: every move arrives instantly.
public final class HeadlessCursorDriver: PresenceCursorDriver {
    public init() {}

    public func moveCursor(
        session: String,
        colorIndex: Int,
        state: CursorState,
        to point: PresencePoint,
        windowID: UInt32?,
        timing: CursorMoveTiming,
        completion: @escaping (CursorMoveOutcome) -> Void
    ) {
        completion(CursorMoveOutcome(point: point, arrived: true, visible: false, cursorWindowID: nil))
    }

    public func pressCursor(session: String, count: Int) {}
    public func setCursorState(session: String, state: CursorState) {}
    public func hideCursor(session: String) {}
    public func removeCursor(session: String) {}
    public func overlayWindowIDs() -> [UInt32] { [] }
}

/// System facts the core reads, injectable for tests.
public struct PresenceEnvironment {
    public var ownPID: pid_t
    public var now: () -> Date
    public var isProcessAlive: (pid_t) -> Bool
    public var frontmostPID: () -> pid_t?
    /// Seconds since the last hardware input of any kind, independent of the event tap.
    public var secondsSinceHIDInput: () -> TimeInterval?
    public var tapAvailable: () -> Bool

    public init(
        ownPID: pid_t = getpid(),
        now: @escaping () -> Date = Date.init,
        isProcessAlive: @escaping (pid_t) -> Bool = PresenceEnvironment.processExists,
        frontmostPID: @escaping () -> pid_t? = { nil },
        secondsSinceHIDInput: @escaping () -> TimeInterval? = { nil },
        tapAvailable: @escaping () -> Bool = { false }
    ) {
        self.ownPID = ownPID
        self.now = now
        self.isProcessAlive = isProcessAlive
        self.frontmostPID = frontmostPID
        self.secondsSinceHIDInput = secondsSinceHIDInput
        self.tapAvailable = tapAvailable
    }

    public static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Request handling over `PresenceState`, with no AppKit and no sockets.
/// Thread-safe: state sits behind a lock, and driver calls happen outside it.
public final class PresenceCore: @unchecked Sendable {
    public typealias Reply = (PresenceResponse) -> Void

    private let lock = NSLock()
    private var state: PresenceState
    private let driver: PresenceCursorDriver
    private let environment: PresenceEnvironment
    /// Holds a display-awake assertion while any session exists.
    private let keepAwake: KeepAwake?
    private var idleSince: Date?
    private var stopping = false
    /// The protocol version each connection greeted with.
    private var greetings: [PresenceConnectionID: Int] = [:]

    /// Called once when a client sends `shutdown`.
    public var onShutdown: (() -> Void)?
    /// Called when the abort chord is seen or `resume` clears it.
    public var onAbortChanged: ((Bool) -> Void)?
    /// Repairs a launch activation, outside the state lock.
    public var onRestoreFocus: ((pid_t, pid_t) -> Void)?

    public init(
        configuration: PresenceStateConfiguration = PresenceStateConfiguration(),
        driver: PresenceCursorDriver,
        environment: PresenceEnvironment = PresenceEnvironment(),
        keepAwake: KeepAwake? = nil
    ) {
        self.state = PresenceState(configuration: configuration)
        self.driver = driver
        self.environment = environment
        self.keepAwake = keepAwake
        self.idleSince = environment.now()
    }

    /// A copy of the current state, for inspection.
    public var snapshot: PresenceState {
        withLock { state }
    }

    // MARK: Connections

    public func connectionOpened(_ id: PresenceConnectionID, peerPID: pid_t?) {
        withLock {
            state.openConnection(id, peerPID: peerPID)
            idleSince = nil
        }
    }

    /// Leases the connection took without a hold go at once, and so do the
    /// sessions it leaves without a lease, cursors included.
    public func connectionClosed(_ id: PresenceConnectionID) {
        let ended = withLock { () -> [String] in
            greetings.removeValue(forKey: id)
            let ended = state.closeConnection(id, now: environment.now())
            updateIdle()
            return ended
        }
        for session in ended {
            driver.removeCursor(session: session)
        }
        syncKeepAwake()
    }

    /// Releases the keep-awake assertion. Called when the process stops.
    public func stop() {
        withLock { stopping = true }
        keepAwake?.update(active: false)
    }

    // MARK: Requests

    public func handle(_ envelope: PresenceRequestEnvelope, connection: PresenceConnectionID, reply: @escaping Reply) {
        let id = envelope.id
        let now = environment.now()
        defer { syncKeepAwake() }

        if withLock({ stopping }) {
            reply(.failure(id: id, .shuttingDown, "The presence process is shutting down."))
            return
        }
        if let session = Self.sessionID(of: envelope.request), session.isEmpty {
            reply(.failure(id: id, .invalidRequest, "Session id must not be empty."))
            return
        }

        switch envelope.request {
        case .hello(let params):
            // Any version registers the client's pid and learns the server's
            // version, so the client can tell an older server (which it replaces)
            // from a newer one (which it leaves alone).
            withLock {
                state.registerClient(connection, pid: params.pid)
                greetings[connection] = params.protocolVersion
            }
            reply(.success(id: id, .hello(HelloResult(
                protocolVersion: PresenceProtocol.version,
                serverPID: environment.ownPID,
                tapAvailable: environment.tapAvailable()
            ))))

        case .sessionAcquire(let params):
            let result = withLock {
                state.acquire(
                    session: params.session,
                    targetPID: params.pid,
                    holdMs: params.holdMs,
                    idleMs: params.idleMs,
                    lingerMs: params.lingerMs,
                    connection: connection,
                    now: now
                )
            }
            switch result {
            case .success(let lease): reply(.success(id: id, .lease(lease)))
            case .failure(let error): reply(PresenceResponse(id: id, outcome: .failure(error)))
            }

        case .sessionRelease(let params):
            let ended = withLock {
                let ended = state.release(session: params.session, targetPID: params.pid, now: now)
                updateIdle()
                return ended
            }
            if ended {
                driver.removeCursor(session: params.session)
            }
            reply(.success(id: id, .empty))

        case .cursorMoveTo(let params):
            guard params.point.x.isFinite, params.point.y.isFinite else {
                reply(.failure(id: id, .invalidRequest, "Point must be finite."))
                return
            }
            let (aborted, record, displayed) = withLock { () -> (Bool, PresenceSessionRecord, CursorState) in
                let record = state.touchSession(params.session, connection: connection, now: now)
                if !state.aborted {
                    state.noteCursorShown(session: params.session)
                }
                return (state.aborted, record, state.displayedState(session: params.session))
            }
            guard !aborted else {
                reply(.failure(id: id, .abortedByUser, Self.abortedMessage))
                return
            }
            let session = params.session
            driver.moveCursor(
                session: session,
                colorIndex: record.colorIndex,
                state: displayed,
                to: params.point,
                windowID: params.windowID,
                timing: params.timing
            ) { outcome in
                reply(.success(id: id, .cursorMove(CursorMoveResult(
                    session: session,
                    point: outcome.point,
                    arrived: outcome.arrived,
                    visible: outcome.visible,
                    cursorWindowID: outcome.cursorWindowID
                ))))
            }

        case .cursorPress(let params):
            let aborted = withLock { () -> Bool in
                state.touchSession(params.session, connection: connection, now: now)
                return state.aborted
            }
            guard !aborted else {
                reply(.failure(id: id, .abortedByUser, Self.abortedMessage))
                return
            }
            driver.pressCursor(session: params.session, count: max(1, min(params.count, 3)))
            reply(.success(id: id, .empty))

        case .cursorSetState(let params):
            let displayed = withLock { () -> CursorState in
                state.setCursorState(params.state, session: params.session, connection: connection, now: now)
                return state.displayedState(session: params.session)
            }
            driver.setCursorState(session: params.session, state: displayed)
            reply(.success(id: id, .empty))

        case .cursorHide(let params):
            withLock { _ = state.touchSession(params.session, connection: connection, now: now) }
            driver.hideCursor(session: params.session)
            reply(.success(id: id, .empty))

        case .guardBegin(let params):
            let frontmost = environment.frontmostPID()
            let hidSeconds = environment.secondsSinceHIDInput()
            let (result, repair) = withLock { () -> (Result<GuardResult, PresenceError>, FocusGuardDecision?) in
                if let session = params.session {
                    state.touchSession(session, connection: connection, now: now)
                    // The guard begins right before delivery: the session is acting.
                    state.noteActed(session: session, targetPID: params.pid, now: now)
                }
                let result = state.beginGuard(targetPID: params.pid, leaseMs: params.leaseMs, frontmostPID: frontmost, now: now, renew: params.renew == true, previousFrontmostPID: params.previousFrontmostPID)
                var repair: FocusGuardDecision?
                if params.renew != true, params.previousFrontmostPID != nil, frontmost == params.pid, case .success = result {
                    repair = state.focusDecision(activatedPID: params.pid, now: now, secondsSinceHIDInput: hidSeconds)
                }
                return (result, repair)
            }
            if case .restore(let previous) = repair {
                onRestoreFocus?(previous, params.pid)
            }
            switch result {
            case .success(let lease): reply(.success(id: id, .guardLease(lease)))
            case .failure(let error): reply(PresenceResponse(id: id, outcome: .failure(error)))
            }

        case .guardEnd(let params):
            withLock { state.endGuard(targetPID: params.pid) }
            reply(.success(id: id, .empty))

        case .status:
            reply(.success(id: id, .status(status())))

        case .resume:
            let changed = setAborted(false)
            reply(.success(id: id, .empty))
            if changed {
                onAbortChanged?(false)
            }

        case .shutdown:
            // A client from an older build would shut down a current server every
            // time it failed to greet it, so only a client that greeted with this
            // version or later may stop it.
            let allowed = withLock { (greetings[connection] ?? 0) >= PresenceProtocol.version }
            guard allowed else {
                reply(.failure(id: id, .unsupportedVersion, "Only a client speaking protocol \(PresenceProtocol.version) or later can stop this presence process."))
                return
            }
            withLock { stopping = true }
            reply(.success(id: id, .empty))
            onShutdown?()
        }
    }

    public func status() -> PresenceStatus {
        let now = environment.now()
        let (aborted, sessions, guarded, restores, lastInput, appInput) = withLock {
            (
                state.aborted,
                state.sessionStatuses(now: now),
                state.guards.keys.sorted(),
                state.guardRestoreStatuses(now: now),
                state.lastUserInputMsAgo(now: now),
                state.appInputStatuses(now: now)
            )
        }
        return PresenceStatus(
            protocolVersion: PresenceProtocol.version,
            serverPID: environment.ownPID,
            aborted: aborted,
            tapAvailable: environment.tapAvailable(),
            overlayWindowIDs: driver.overlayWindowIDs(),
            sessions: sessions,
            guardedPIDs: guarded,
            guardRestores: restores,
            keepAwake: keepAwake.flatMap { $0.isEnabled ? $0.isHeld : nil },
            lastUserInputMsAgo: lastInput,
            appInput: appInput
        )
    }

    // MARK: Events from the AppKit layer

    /// One input event from the listen-only tap. `targetPID` is the app it went to.
    @discardableResult
    public func recordUserInput(
        sourcePID: pid_t,
        targetPID: pid_t?,
        kind: UserInputKind = .deliberate,
        isAbortChord: Bool
    ) -> UserInputEffect {
        let (effect, wasAborted) = withLock { () -> (UserInputEffect, Bool) in
            let wasAborted = state.aborted
            let effect = state.recordUserInput(
                sourcePID: sourcePID,
                targetPID: targetPID,
                kind: kind,
                isAbortChord: isAbortChord,
                ownPID: environment.ownPID,
                now: environment.now()
            )
            return (effect, wasAborted)
        }
        if effect == .aborted && !wasAborted {
            refreshDisplayedStates()
            onAbortChanged?(true)
        }
        return effect
    }

    /// Called when any app activates. `previousPID` is the app that was frontmost
    /// just before. Returns what the focus guard decided.
    public func applicationActivated(pid: pid_t, previousPID: pid_t? = nil) -> FocusGuardDecision {
        let hidSeconds = environment.secondsSinceHIDInput()
        return withLock {
            state.focusDecision(activatedPID: pid, deactivatedPID: previousPID, now: environment.now(), secondsSinceHIDInput: hidSeconds)
        }
    }

    /// Called when the active Space changes.
    public func spaceChanged() {
        withLock { state.recordSpaceChange(now: environment.now()) }
    }

    /// Periodic housekeeping. Returns how long the process has been idle.
    @discardableResult
    public func tick() -> TimeInterval {
        let now = environment.now()
        let (swept, idleFor) = withLock { () -> (PresenceSweep, TimeInterval) in
            let swept = state.sweep(now: now, isProcessAlive: environment.isProcessAlive)
            updateIdle()
            return (swept, idleSince.map { now.timeIntervalSince($0) } ?? 0)
        }
        for session in swept.hidden {
            driver.hideCursor(session: session)
        }
        for session in swept.ended {
            driver.removeCursor(session: session)
        }
        syncKeepAwake()
        return idleFor
    }

    /// Keeps the display awake while any session exists, and never after a stop.
    private func syncKeepAwake() {
        guard let keepAwake else {
            return
        }
        let active = withLock { !stopping && !state.sessions.isEmpty }
        keepAwake.update(active: active)
    }

    // MARK: Private

    private static let abortedMessage = "Stopped by the user. Run `screencommander resume` to continue."

    private static func sessionID(of request: PresenceRequest) -> String? {
        switch request {
        case .sessionAcquire(let params): return params.session
        case .sessionRelease(let params): return params.session
        case .cursorMoveTo(let params): return params.session
        case .cursorPress(let params): return params.session
        case .cursorSetState(let params): return params.session
        case .cursorHide(let params): return params.session
        case .guardBegin(let params): return params.session
        case .hello, .guardEnd, .status, .resume, .shutdown: return nil
        }
    }

    /// Returns true when the flag changed.
    private func setAborted(_ value: Bool) -> Bool {
        let changed = withLock { () -> Bool in
            guard state.aborted != value else {
                return false
            }
            if !value {
                state.resume()
            }
            return true
        }
        if changed {
            refreshDisplayedStates()
        }
        return changed
    }

    private func refreshDisplayedStates() {
        let states = withLock {
            state.sessions.keys.map { ($0, state.displayedState(session: $0)) }
        }
        for (session, displayed) in states {
            driver.setCursorState(session: session, state: displayed)
        }
    }

    /// Caller holds the lock.
    private func updateIdle() {
        if state.isIdle {
            if idleSince == nil {
                idleSince = environment.now()
            }
        } else {
            idleSince = nil
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
