import AppKit
import Foundation

public struct PresenceServerConfiguration: Sendable {
    public var socketPath: String
    /// Exit after this long with no sessions, no focus guard, and no abort in
    /// force. A client that stays connected does not keep the process alive.
    public var idleTimeout: TimeInterval
    public var state = PresenceStateConfiguration()
    public var motion = CursorMotionTuning()
    /// Housekeeping cadence: lease expiry, window following, z-order, idle check.
    public var tickInterval: TimeInterval = 0.25
    /// How often to retry the event tap while it is unavailable.
    public var tapRetryInterval: TimeInterval = 30
    /// Hold a display-awake assertion while any session exists.
    public var keepAwake = true

    public init(socketPath: String, idleTimeout: TimeInterval = 120, keepAwake: Bool = true) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.keepAwake = keepAwake
    }
}

/// The presence process: cursor windows, focus guard, user-input tap, abort
/// key, and leases, served over a Unix socket.
///
/// The socket and state layers (`PresenceSocketServer`, `PresenceCore`) run
/// without AppKit. This type puts the AppKit pieces on top: an accessory
/// `NSApplication` (no Dock icon, never frontmost), the cursor overlay driver,
/// the event tap, and the workspace observers.
public final class PresenceServer {
    public let configuration: PresenceServerConfiguration

    private var core: PresenceCore?
    private var socket: PresenceSocketServer?
    private var overlays: CursorOverlayController?
    private var tap: UserInputTap?
    private var tickTimer: Timer?
    private var lastTapAttempt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var stopping = false

    public init(configuration: PresenceServerConfiguration) {
        self.configuration = configuration
    }

    /// Runs until idle timeout, `shutdown`, SIGTERM, or SIGINT. Call on the
    /// main thread of a process that has nothing else to do. Throws
    /// `PresenceSocketError.alreadyRunning` when another presence process
    /// serves the socket, and returns normally after a clean stop.
    public func run() throws {
        dispatchPrecondition(condition: .onQueue(.main))

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let overlays = CursorOverlayController(tuning: configuration.motion)
        let frontmost = FrontmostTracker()
        let tapState = TapState()
        let environment = PresenceEnvironment(
            frontmostPID: { frontmost.pid },
            secondsSinceHIDInput: PresenceServer.secondsSinceHIDInput,
            tapAvailable: { tapState.available }
        )
        let core = PresenceCore(
            configuration: configuration.state,
            driver: overlays,
            environment: environment,
            keepAwake: KeepAwake(assertion: configuration.keepAwake ? DisplaySleepAssertion() : nil)
        )

        // The tap comes up before the socket so the first `hello` reports it accurately.
        let pointerApps = PointerAppResolver()
        let tap = UserInputTap { input in
            // Runs on the main run loop, so reading the frontmost app here is safe.
            // Keys go to the frontmost app. Clicks, scrolls, and gestures go to the
            // app under the pointer, which may be in the background.
            var target: pid_t?
            if input.kind == .deliberate {
                target = input.windowUnderPointer.flatMap(pointerApps.pid(ofWindow:))
                    ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            core.recordUserInput(sourcePID: input.sourcePID, targetPID: target, kind: input.kind, isAbortChord: input.isAbortChord)
        }
        self.tap = tap
        tapState.available = tap.start()
        lastTapAttempt = Date()

        let socket = PresenceSocketServer(socketPath: configuration.socketPath, core: core)
        do {
            try socket.start()
        } catch {
            tap.stop()
            self.tap = nil
            throw error
        }

        self.core = core
        self.socket = socket
        self.overlays = overlays

        core.onShutdown = { [weak self] in
            DispatchQueue.main.async { self?.stop() }
        }

        observeWorkspace(core: core, overlays: overlays, frontmost: frontmost)
        installSignalHandlers()

        let timer = Timer(timeInterval: configuration.tickInterval, repeats: true) { [weak self] _ in
            self?.tick(tapState: tapState)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        app.run()
        tearDown()
    }

    /// Stops the run loop. Main thread.
    public func stop() {
        guard !stopping else {
            return
        }
        stopping = true
        NSApp.stop(nil)
        // `stop` takes effect after the next event, so post one.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: Private

    private func tick(tapState: TapState) {
        guard let core, let overlays else {
            return
        }
        let idleFor = core.tick()
        overlays.refresh()

        if !tapState.available, Date().timeIntervalSince(lastTapAttempt) >= configuration.tapRetryInterval {
            lastTapAttempt = Date()
            tapState.available = tap?.start() ?? false
        }

        if idleFor >= configuration.idleTimeout {
            stop()
        }
    }

    private func observeWorkspace(core: PresenceCore, overlays: CursorOverlayController, frontmost: FrontmostTracker) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let deactivated = frontmost.pid
            frontmost.pid = app.processIdentifier
            if case .restore(let previous) = core.applicationActivated(pid: app.processIdentifier, previousPID: deactivated) {
                PresenceServer.reactivate(previous, takingFocusFrom: app)
            }
            // The newly active app may have raised the window a cursor sits above.
            overlays.refresh()
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            core.spaceChanged()
        })
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stop()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func tearDown() {
        core?.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        tap?.stop()
        tap = nil
        overlays?.removeAll()
        socket?.stop()
        socket = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
    }

    /// Puts the previously frontmost app back after a focus steal. macOS 14's
    /// cooperative activation honors a request made on behalf of the app that
    /// currently holds focus, so that is tried first.
    static func reactivate(_ pid: pid_t, takingFocusFrom thief: NSRunningApplication) {
        guard let previous = NSRunningApplication(processIdentifier: pid), !previous.isTerminated else {
            return
        }
        if !previous.activate(from: thief, options: []) {
            previous.activate(options: [])
        }
    }

    /// Seconds since the last hardware input of any kind: keys, modifiers,
    /// buttons, pointer motion, scrolls, and gestures. Works without the event
    /// tap and while secure input hides keys from it, so the focus guard can
    /// still tell a user's switch from a steal.
    static func secondsSinceHIDInput() -> TimeInterval? {
        UserInputTap.hidIdleTypes
            .compactMap { CGEventType(rawValue: $0) }
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min()
    }
}

/// Maps a window number to its owner's pid, cached because a scroll or a
/// gesture sends many events to the same window.
private final class PointerAppResolver {
    private var owners: [UInt32: pid_t] = [:]

    func pid(ofWindow windowID: UInt32) -> pid_t? {
        if let pid = owners[windowID] {
            return pid
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? pid_t, pid > 0 else {
            return nil
        }
        if owners.count >= 256 {
            owners.removeAll()
        }
        owners[windowID] = pid
        return pid
    }
}

/// Frontmost pid, updated on the main thread and read from the core's callers.
private final class FrontmostTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    init() {
        value = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    var pid: pid_t? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var available: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
