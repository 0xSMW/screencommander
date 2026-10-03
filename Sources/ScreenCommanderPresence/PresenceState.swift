import Foundation

/// Identifies one socket connection to the presence process.
public typealias PresenceConnectionID = UInt64

public struct PresenceStateConfiguration: Equatable, Sendable {
    /// How long a session stays `userActive` after the last real input.
    public var userQuietPeriod: TimeInterval = 1.0
    /// A lease is released once its session has not acted on the target app for
    /// this long, unless `session.acquire` names another period.
    public var leaseIdle: TimeInterval = 15
    /// How long a session's cursor stays on screen after the session's last
    /// request, unless `session.acquire` names another period. A session with no
    /// leases ends after the same period.
    public var cursorLinger: TimeInterval = 10
    /// See `FocusGuardPolicy.defaultUserCauseWindow`.
    public var userCauseWindow: TimeInterval = FocusGuardPolicy.defaultUserCauseWindow
    /// Upper bound on `guard.begin` lease length.
    public var maximumGuardLease: TimeInterval = 30
    /// Upper bound on a lease's idle period and its hold after a disconnect.
    public var maximumLeaseHold: TimeInterval = 600
    /// Upper bound on a session's cursor linger.
    public var maximumCursorLinger: TimeInterval = 120
    /// A client pid stays trusted this long after its connection closes, so
    /// input it posted just before exiting is not mistaken for the user's.
    public var clientPIDRetention: TimeInterval = 5
    /// Per-app input older than this is forgotten.
    public var appInputRetention: TimeInterval = 30
    /// At most this many apps keep a per-app input record.
    public var appInputLimit = 32
    /// Number of distinct cursor tints.
    public var paletteSize = CursorPalette.count

    public init() {}
}

/// A lease on one target app.
public struct PresenceLease: Equatable, Sendable {
    public var session: String
    public var targetPID: pid_t
    /// Open connection that holds the lease, or nil once that client went away.
    public var owner: PresenceConnectionID?
    /// How long the lease may outlive its connection. Zero drops it on disconnect.
    public var hold: TimeInterval
    /// The lease is released this long after the session last acted on the target.
    public var idle: TimeInterval
    /// When the session last acted on the target.
    public var lastActedAt: Date
    /// Set once the owner disconnects with a non-zero hold.
    public var expiresAt: Date?

    /// When the lease runs out if nothing renews it.
    public var deadline: Date {
        let idleDeadline = lastActedAt.addingTimeInterval(idle)
        guard let expiresAt else {
            return idleDeadline
        }
        return min(idleDeadline, expiresAt)
    }
}

public struct PresenceSessionRecord: Equatable, Sendable {
    public var id: String
    public var colorIndex: Int
    public var state: CursorState = .idle
    public var connections: Set<PresenceConnectionID> = []
    public var lastActivityAt: Date
    public var lastUserInputAt: Date?
    /// How long the cursor stays after the session's last request.
    public var linger: TimeInterval
    /// The cursor was faded out for lingering, and the next glide brings it back.
    public var cursorHidden = false
}

/// What a recorded input event changed.
public enum UserInputEffect: Equatable, Sendable {
    case ignored
    case recorded(sessions: [String])
    case aborted
}

/// How much an input event says about what the user is doing.
public enum UserInputKind: Equatable, Sendable {
    /// A key press, a click, a scroll, or a gesture: the user is working in the
    /// app it went to.
    case deliberate
    /// Pointer motion, a key or button release, or a modifier change: the user is
    /// at the Mac, but this does not say which app they are working in.
    case ambient
}

/// What a sweep changed, so the caller can update cursors.
public struct PresenceSweep: Equatable, Sendable {
    /// Sessions that ended. Their cursors are removed.
    public var ended: [String] = []
    /// Sessions whose cursor lingered long enough to fade out.
    public var hidden: [String] = []
}

/// All presence bookkeeping as a value type: leases, sessions, client pids,
/// user activity, the abort flag, and focus guards. Every mutation takes
/// `now` so tests control time. `PresenceCore` wraps this with a lock and the
/// side effects.
///
/// Nothing stays alive only because a connection is open. A lease ends when its
/// session has not acted on the app for the lease's idle period, a session ends
/// once it holds no leases and its cursor has lingered, and a closed connection
/// drops the leases it took without a hold at once.
public struct PresenceState: Sendable {
    public var configuration: PresenceStateConfiguration
    public private(set) var sessions: [String: PresenceSessionRecord] = [:]
    public private(set) var leases: [pid_t: PresenceLease] = [:]
    /// Open connections and the client pids known for each.
    public private(set) var connections: [PresenceConnectionID: Set<pid_t>] = [:]
    public private(set) var recentClientPIDs: [pid_t: Date] = [:]
    public private(set) var guards: [pid_t: FocusGuardLease] = [:]
    public private(set) var aborted = false
    /// Last real input of any kind.
    public private(set) var lastUserInputAt: Date?
    /// Last deliberate input per app, whether or not a session leases the app.
    public private(set) var appInput: [pid_t: Date] = [:]
    public private(set) var lastSpaceChangeAt: Date?

    public init(configuration: PresenceStateConfiguration = PresenceStateConfiguration()) {
        self.configuration = configuration
    }

    /// Idle means the process may exit: no session, no guard, and no abort in
    /// force. Open connections do not count, so a client that stays connected
    /// (`serve`) does not keep the process alive by itself. Never while the abort
    /// key is in force: the flag lives only in this process, so exiting would
    /// silently lift the user's stop.
    public var isIdle: Bool {
        sessions.isEmpty && guards.isEmpty && !aborted
    }

    // MARK: Connections

    public mutating func openConnection(_ id: PresenceConnectionID, peerPID: pid_t?) {
        connections[id] = Set([peerPID].compactMap { $0 }.filter { $0 > 0 })
    }

    /// `hello` registers the pid the client reports, alongside the peer pid
    /// read from the socket.
    public mutating func registerClient(_ id: PresenceConnectionID, pid: pid_t) {
        guard pid > 0 else {
            return
        }
        connections[id, default: []].insert(pid)
    }

    /// Drops the connection. Leases it took without a hold are released at once.
    /// Held leases keep running toward their deadline. A session that was attached
    /// to this connection and now holds no lease ends. Returns the ended sessions.
    @discardableResult
    public mutating func closeConnection(_ id: PresenceConnectionID, now: Date) -> [String] {
        for pid in connections.removeValue(forKey: id) ?? [] {
            recentClientPIDs[pid] = now.addingTimeInterval(configuration.clientPIDRetention)
        }
        for (pid, lease) in leases where lease.owner == id {
            if lease.hold > 0 {
                leases[pid]?.owner = nil
                leases[pid]?.expiresAt = now.addingTimeInterval(lease.hold)
            } else {
                leases.removeValue(forKey: pid)
            }
        }
        var ended: [String] = []
        for key in Array(sessions.keys) where sessions[key]?.connections.remove(id) != nil {
            if leasedPIDs(for: key).isEmpty {
                sessions.removeValue(forKey: key)
                ended.append(key)
            }
        }
        return ended.sorted()
    }

    public func isClientPID(_ pid: pid_t, now: Date) -> Bool {
        if connections.values.contains(where: { $0.contains(pid) }) {
            return true
        }
        if let until = recentClientPIDs[pid], now < until {
            return true
        }
        return false
    }

    // MARK: Sessions

    /// Returns the session, creating it with the lowest free palette slot.
    @discardableResult
    public mutating func touchSession(_ id: String, connection: PresenceConnectionID?, now: Date) -> PresenceSessionRecord {
        if sessions[id] == nil {
            let used = Set(sessions.values.map(\.colorIndex))
            let size = max(1, configuration.paletteSize)
            let free = (0..<size).first { !used.contains($0) } ?? (sessions.count % size)
            sessions[id] = PresenceSessionRecord(id: id, colorIndex: free, lastActivityAt: now, linger: configuration.cursorLinger)
        }
        sessions[id]?.lastActivityAt = now
        if let connection {
            sessions[id]?.connections.insert(connection)
        }
        return sessions[id]!
    }

    public mutating func setCursorState(_ state: CursorState, session: String, connection: PresenceConnectionID?, now: Date) {
        touchSession(session, connection: connection, now: now)
        sessions[session]?.state = state
    }

    /// A glide puts the cursor back on screen.
    public mutating func noteCursorShown(session: String) {
        sessions[session]?.cursorHidden = false
    }

    /// Ends a session outright and drops every lease it holds.
    public mutating func endSession(_ id: String) {
        sessions.removeValue(forKey: id)
        for (pid, lease) in leases where lease.session == id {
            leases.removeValue(forKey: pid)
        }
    }

    // MARK: Leases

    public mutating func acquire(
        session: String,
        targetPID: pid_t,
        holdMs: Int?,
        idleMs: Int? = nil,
        lingerMs: Int? = nil,
        connection: PresenceConnectionID,
        now: Date
    ) -> Result<LeaseResult, PresenceError> {
        guard targetPID > 0 else {
            return .failure(PresenceError(code: .invalidRequest, message: "Target pid must be positive."))
        }
        guard !session.isEmpty else {
            return .failure(PresenceError(code: .invalidRequest, message: "Session id must not be empty."))
        }
        if aborted {
            return .failure(PresenceError(code: .abortedByUser, message: "Stopped by the user. Run `screencommander resume` to continue."))
        }
        if let existing = leases[targetPID], existing.session != session, now < existing.deadline {
            return .failure(PresenceError(
                code: .targetBusy,
                message: "Session \(existing.session) holds the lease on pid \(targetPID)."
            ))
        }
        let cap = configuration.maximumLeaseHold
        let hold = min(max(Double(holdMs ?? 0) / 1000, 0), cap)
        let idle = idleMs.map { min(max(Double($0) / 1000, 0.1), cap) } ?? configuration.leaseIdle
        // Re-acquiring your own lease, from this or a new connection, renews it.
        leases[targetPID] = PresenceLease(
            session: session, targetPID: targetPID, owner: connection, hold: hold, idle: idle, lastActedAt: now, expiresAt: nil
        )
        let record = touchSession(session, connection: connection, now: now)
        if let lingerMs {
            sessions[session]?.linger = min(max(Double(lingerMs) / 1000, 0), configuration.maximumCursorLinger)
        }
        return .success(LeaseResult(session: session, pid: targetPID, colorIndex: record.colorIndex))
    }

    /// The session acted on the target: the lease's idle clock starts again.
    public mutating func noteActed(session: String, targetPID: pid_t, now: Date) {
        guard leases[targetPID]?.session == session else {
            return
        }
        leases[targetPID]?.lastActedAt = now
    }

    /// Releases one lease, or with no pid every lease of the session and the
    /// session itself. Returns true when the session ended.
    @discardableResult
    public mutating func release(session: String, targetPID: pid_t?, now: Date) -> Bool {
        if let targetPID {
            if leases[targetPID]?.session == session {
                leases.removeValue(forKey: targetPID)
            }
            if sessions[session] != nil {
                sessions[session]?.lastActivityAt = now
            }
            return false
        }
        let existed = sessions[session] != nil
        endSession(session)
        return existed
    }

    public func leasedPIDs(for session: String) -> [pid_t] {
        leases.values.filter { $0.session == session }.map(\.targetPID).sorted()
    }

    /// Expires idle and held leases, leases on dead targets, stale client pids,
    /// ended guards, and old per-app input. Fades out cursors that lingered, and
    /// ends sessions that hold no lease once they lingered.
    public mutating func sweep(now: Date, isProcessAlive: (pid_t) -> Bool) -> PresenceSweep {
        for (pid, lease) in leases where now >= lease.deadline || !isProcessAlive(pid) {
            leases.removeValue(forKey: pid)
        }
        recentClientPIDs = recentClientPIDs.filter { now < $0.value }
        guards = guards.filter { now < $0.value.expiresAt }
        pruneAppInput(now: now)

        var result = PresenceSweep()
        for (id, record) in sessions {
            let quietFor = now.timeIntervalSince(record.lastActivityAt)
            guard quietFor >= record.linger else {
                continue
            }
            if leases.values.contains(where: { $0.session == id }) {
                if !record.cursorHidden {
                    sessions[id]?.cursorHidden = true
                    result.hidden.append(id)
                }
            } else {
                result.ended.append(id)
            }
        }
        for id in result.ended {
            sessions.removeValue(forKey: id)
        }
        result.ended.sort()
        result.hidden.sort()
        return result
    }

    // MARK: User activity and abort

    /// Records one input event seen by the event tap. `targetPID` is the app the
    /// event went to: the frontmost app for keys, the app under the pointer for
    /// clicks, scrolls, and gestures.
    public mutating func recordUserInput(
        sourcePID: pid_t,
        targetPID: pid_t?,
        kind: UserInputKind = .deliberate,
        isAbortChord: Bool,
        ownPID: pid_t,
        now: Date
    ) -> UserInputEffect {
        if sourcePID != 0 && (sourcePID == ownPID || isClientPID(sourcePID, now: now)) {
            return .ignored
        }
        lastUserInputAt = now
        if isAbortChord {
            aborted = true
            return .aborted
        }
        guard kind == .deliberate, let targetPID, targetPID > 0 else {
            return .recorded(sessions: [])
        }
        appInput[targetPID] = now
        if appInput.count > configuration.appInputLimit {
            pruneAppInput(now: now)
        }
        guard let lease = leases[targetPID], sessions[lease.session] != nil else {
            return .recorded(sessions: [])
        }
        sessions[lease.session]?.lastUserInputAt = now
        return .recorded(sessions: [lease.session])
    }

    /// The active Space changed, which only the user does.
    public mutating func recordSpaceChange(now: Date) {
        lastSpaceChangeAt = now
    }

    public func isUserActive(session: String, now: Date) -> Bool {
        guard let last = sessions[session]?.lastUserInputAt else {
            return false
        }
        return now.timeIntervalSince(last) < configuration.userQuietPeriod
    }

    public mutating func resume() {
        aborted = false
    }

    /// The state a session's cursor should show. Abort overrides to paused.
    public func displayedState(session: String) -> CursorState {
        aborted ? .paused : (sessions[session]?.state ?? .idle)
    }

    private mutating func pruneAppInput(now: Date) {
        appInput = appInput.filter { now.timeIntervalSince($0.value) < configuration.appInputRetention }
        let limit = max(1, configuration.appInputLimit)
        if appInput.count > limit {
            let keep = appInput.sorted { $0.value > $1.value }.prefix(limit)
            appInput = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: Focus guard

    /// Begins or renews the guard on `targetPID`. Each renewal samples the
    /// frontmost app again, so the guard never holds on to an app the user has
    /// since left.
    public mutating func beginGuard(targetPID: pid_t, leaseMs: Int, frontmostPID: pid_t?, now: Date) -> Result<GuardResult, PresenceError> {
        guard targetPID > 0 else {
            return .failure(PresenceError(code: .invalidRequest, message: "Target pid must be positive."))
        }
        let lease = min(max(Double(leaseMs) / 1000, 0), configuration.maximumGuardLease)
        let previous = frontmostPID == targetPID ? nil : frontmostPID
        let lastRestoreAt = guards[targetPID]?.lastRestoreAt
        guards[targetPID] = FocusGuardLease(
            targetPID: targetPID, previousFrontmostPID: previous, beganAt: now, expiresAt: now.addingTimeInterval(lease)
        )
        guards[targetPID]?.lastRestoreAt = lastRestoreAt
        return .success(GuardResult(pid: targetPID, previousFrontmostPID: previous, leaseMs: Int((lease * 1000).rounded())))
    }

    public mutating func endGuard(targetPID: pid_t) {
        guards.removeValue(forKey: targetPID)
    }

    /// - Parameter deactivatedPID: the app that was frontmost just before the activation.
    public mutating func focusDecision(
        activatedPID: pid_t,
        deactivatedPID: pid_t? = nil,
        now: Date,
        secondsSinceHIDInput: TimeInterval?
    ) -> FocusGuardDecision {
        let decision = FocusGuardPolicy.decide(
            activatedPID: activatedPID,
            deactivatedPID: deactivatedPID,
            now: now,
            guardLease: guards[activatedPID],
            user: UserActivitySignals(
                lastInputAt: lastUserInputAt,
                secondsSinceHIDInput: secondsSinceHIDInput,
                lastSpaceChangeAt: lastSpaceChangeAt
            ),
            userCauseWindow: configuration.userCauseWindow
        )
        switch decision {
        case .restore:
            guards[activatedPID]?.restoreCount += 1
            guards[activatedPID]?.lastRestoreAt = now
        case .ignore(.userCaused):
            // The user took the app on purpose. Stop guarding it.
            guards.removeValue(forKey: activatedPID)
        case .ignore:
            break
        }
        return decision
    }

    // MARK: Status

    public func guardRestoreStatuses(now: Date) -> [GuardRestoreStatus] {
        guards.values.sorted { $0.targetPID < $1.targetPID }.map { lease in
            GuardRestoreStatus(
                pid: lease.targetPID,
                restoreCount: lease.restoreCount,
                lastRestoreMsAgo: lease.lastRestoreAt.map { Self.msAgo($0, now: now) }
            )
        }
    }

    public func sessionStatuses(now: Date) -> [SessionStatus] {
        sessions.values.sorted { $0.id < $1.id }.map { record in
            SessionStatus(
                id: record.id,
                pids: leasedPIDs(for: record.id),
                userActive: isUserActive(session: record.id, now: now),
                lastUserInputMsAgo: record.lastUserInputAt.map { Self.msAgo($0, now: now) },
                state: displayedState(session: record.id),
                colorIndex: record.colorIndex
            )
        }
    }

    public func appInputStatuses(now: Date) -> [AppInputStatus] {
        appInput
            .filter { now.timeIntervalSince($0.value) < configuration.appInputRetention }
            .sorted { $0.value > $1.value }
            .prefix(max(1, configuration.appInputLimit))
            .map { AppInputStatus(pid: $0.key, lastInputMsAgo: Self.msAgo($0.value, now: now)) }
    }

    public func lastUserInputMsAgo(now: Date) -> Int? {
        lastUserInputAt.map { Self.msAgo($0, now: now) }
    }

    private static func msAgo(_ date: Date, now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(date) * 1000).rounded()))
    }
}
