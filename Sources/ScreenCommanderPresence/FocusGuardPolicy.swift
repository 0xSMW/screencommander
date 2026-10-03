import Foundation

/// A focus-steal lease on one target app, opened by `guard.begin`.
public struct FocusGuardLease: Equatable, Sendable {
    public var targetPID: pid_t
    /// The app that was frontmost when the guard last began or was renewed. Nil
    /// when the target itself was frontmost, which leaves nothing to put back.
    public var previousFrontmostPID: pid_t?
    /// When the action this lease covers began.
    public var beganAt: Date
    public var expiresAt: Date
    public var restoreCount = 0
    /// When the guard last put the previous app back, kept across renewals.
    public var lastRestoreAt: Date?

    public init(targetPID: pid_t, previousFrontmostPID: pid_t?, beganAt: Date, expiresAt: Date) {
        self.targetPID = targetPID
        self.previousFrontmostPID = previousFrontmostPID
        self.beganAt = beganAt
        self.expiresAt = expiresAt
    }
}

public enum FocusGuardDecision: Equatable, Sendable {
    case ignore(FocusGuardIgnoreReason)
    /// Reactivate this pid.
    case restore(pid_t)
}

public enum FocusGuardIgnoreReason: Equatable, Sendable {
    case notGuarded
    case leaseExpired
    case userCaused
    case nothingToRestore
    case restoreLimitReached
}

/// What the guard knows about the user around an activation.
public struct UserActivitySignals: Equatable, Sendable {
    /// Last real input of any kind seen by the listen-only tap.
    public var lastInputAt: Date?
    /// Seconds since the last hardware input of any kind, from the HID event
    /// source. Works without the tap and sees input the tap misses, such as keys
    /// typed while secure input is on.
    public var secondsSinceHIDInput: TimeInterval?
    /// Last change of the active Space.
    public var lastSpaceChangeAt: Date?

    public init(lastInputAt: Date? = nil, secondsSinceHIDInput: TimeInterval? = nil, lastSpaceChangeAt: Date? = nil) {
        self.lastInputAt = lastInputAt
        self.secondsSinceHIDInput = secondsSinceHIDInput
        self.lastSpaceChangeAt = lastSpaceChangeAt
    }
}

/// Decides whether an app activation was a focus steal worth undoing.
///
/// The guard only undoes an activation of the target app inside the lease that
/// followed the agent's own action. Anything that hints at the user is read as
/// the user's choice, so when in doubt it does nothing: any real input in the
/// cause window (keys, modifiers such as a held Command-Tab, clicks, pointer
/// motion, scrolls, trackpad swipes and other gestures) and any Space change.
/// It puts back the app the activation took focus from, which is the app the
/// user was in at that moment, never an app sampled earlier that the user has
/// since left.
public enum FocusGuardPolicy {
    /// Real user input or a Space change inside this window before an activation
    /// means the user caused it.
    public static let defaultUserCauseWindow: TimeInterval = 1.5
    /// An app that keeps re-activating itself is put back at most this many times per lease.
    public static let maximumRestores = 3

    /// - Parameter deactivatedPID: the app that was frontmost just before this
    ///   activation, when known.
    public static func decide(
        activatedPID: pid_t,
        deactivatedPID: pid_t?,
        now: Date,
        guardLease: FocusGuardLease?,
        user: UserActivitySignals,
        userCauseWindow: TimeInterval = defaultUserCauseWindow
    ) -> FocusGuardDecision {
        guard let guardLease, guardLease.targetPID == activatedPID else {
            return .ignore(.notGuarded)
        }
        guard now < guardLease.expiresAt else {
            return .ignore(.leaseExpired)
        }
        if let last = user.lastInputAt, now.timeIntervalSince(last) <= userCauseWindow {
            return .ignore(.userCaused)
        }
        if let seconds = user.secondsSinceHIDInput, seconds >= 0, seconds <= userCauseWindow {
            return .ignore(.userCaused)
        }
        if let spaceChange = user.lastSpaceChangeAt, now.timeIntervalSince(spaceChange) <= userCauseWindow {
            return .ignore(.userCaused)
        }
        // Nil previous: the target was frontmost when the action began.
        guard let previous = guardLease.previousFrontmostPID, previous != activatedPID else {
            return .ignore(.nothingToRestore)
        }
        let displaced = deactivatedPID ?? previous
        guard displaced != activatedPID, displaced > 0 else {
            return .ignore(.nothingToRestore)
        }
        guard guardLease.restoreCount < maximumRestores else {
            return .ignore(.restoreLimitReached)
        }
        return .restore(displaced)
    }
}
