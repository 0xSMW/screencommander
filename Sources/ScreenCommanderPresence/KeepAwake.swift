import Foundation
import IOKit.pwr_mgt

/// One power assertion that can be taken and released. `DisplaySleepAssertion` in
/// production, a fake in tests.
public protocol PowerAssertionHolding: AnyObject {
    /// Takes the assertion. Returns false when the system refused it.
    func take() -> Bool
    func release()
}

/// Keeps the display awake, and with it holds off the screen saver, the way
/// `caffeinate -d` does. It never wakes a display that is already asleep and never
/// dismisses a running screen saver or a locked screen.
public final class DisplaySleepAssertion: PowerAssertionHolding {
    public static let defaultReason = "screencommander: an agent session is active"

    private let reason: String
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    public init(reason: String = DisplaySleepAssertion.defaultReason) {
        self.reason = reason
    }

    public func take() -> Bool {
        guard !held else {
            return true
        }
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        held = result == kIOReturnSuccess
        return held
    }

    public func release() {
        guard held else {
            return
        }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit {
        release()
    }
}

/// Holds a power assertion while something is active and releases it otherwise.
/// Thread-safe. With no assertion (keep-awake turned off) it never holds anything.
public final class KeepAwake: @unchecked Sendable {
    /// `SCREENCOMMANDER_KEEP_AWAKE=0` (or `false`, `no`, `off`) turns keep-awake off.
    public static let environmentKey = "SCREENCOMMANDER_KEEP_AWAKE"

    private let assertion: PowerAssertionHolding?
    private let lock = NSLock()
    private var held = false

    public init(assertion: PowerAssertionHolding?) {
        self.assertion = assertion
    }

    /// The live keep-awake for this process's environment: off when the variable
    /// says so, else a display-sleep assertion.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> KeepAwake {
        KeepAwake(assertion: isEnabled(environment: environment) ? DisplaySleepAssertion() : nil)
    }

    public static func isEnabled(environment: [String: String]) -> Bool {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    public var isEnabled: Bool {
        assertion != nil
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Takes the assertion when `active` and it is not held, releases it when not
    /// `active` and it is held.
    public func update(active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let assertion else {
            return
        }
        if active, !held {
            held = assertion.take()
        } else if !active, held {
            assertion.release()
            held = false
        }
    }
}

/// Keeps the display awake for a while after each piece of activity. `serve` uses
/// it for its tool calls when presence is disabled, since presence normally holds
/// the assertion for active sessions.
public final class ActivityKeepAwake: @unchecked Sendable {
    public let keepAwake: KeepAwake
    public let idleWindow: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var lastActivity: Date?

    public init(keepAwake: KeepAwake, idleWindow: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.keepAwake = keepAwake
        self.idleWindow = idleWindow
        self.now = now
    }

    public func noteActivity() {
        lock.lock()
        lastActivity = now()
        lock.unlock()
        keepAwake.update(active: true)
    }

    /// Releases the assertion once `idleWindow` has passed with no activity.
    public func tick() {
        lock.lock()
        let idle = lastActivity.map { now().timeIntervalSince($0) >= idleWindow } ?? true
        lock.unlock()
        if idle {
            keepAwake.update(active: false)
        }
    }

    public func stop() {
        keepAwake.update(active: false)
    }
}
