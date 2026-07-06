import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Event kinds

/// Categories of UI change selectable via `observe --events`. Each category maps to
/// one or more underlying AX notifications (or, for `.app`, NSWorkspace lifecycle
/// notifications).
enum ObservedEventKind: String, Codable, Sendable, CaseIterable {
    case value
    case focus
    case window
    case destroy
    case app

    /// Parses a comma-separated `--events` list (e.g. "value,focus"); an empty or
    /// nil list means "all kinds". Unknown tokens throw `invalid_arguments`.
    static func parseList(_ raw: String?) throws -> Set<ObservedEventKind> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Set(ObservedEventKind.allCases)
        }
        var kinds: Set<ObservedEventKind> = []
        for token in raw.split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            guard let kind = ObservedEventKind(rawValue: name) else {
                let valid = ObservedEventKind.allCases.map(\.rawValue).joined(separator: ", ")
                throw ScreenCommanderError.invalidArguments(
                    "Unknown --events value '\(name)'. Valid values: \(valid)."
                )
            }
            kinds.insert(kind)
        }
        guard !kinds.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--events was given no recognizable values.")
        }
        return kinds
    }
}

// MARK: - Notification mapping

/// Maps AX/NSWorkspace notification names to a `(kind, event-name)` pair. Pure and
/// unit-tested; the production observer registers exactly the names for the requested
/// kinds and stamps emitted events with the matching event name.
enum ObservedNotification {
    /// AX notification name → (kind, wire event name).
    static let axMapping: [(name: String, kind: ObservedEventKind, event: String)] = [
        (kAXValueChangedNotification as String, .value, "value_changed"),
        (kAXFocusedUIElementChangedNotification as String, .focus, "focus_changed"),
        (kAXWindowCreatedNotification as String, .window, "window_created"),
        (kAXWindowMovedNotification as String, .window, "window_moved"),
        (kAXWindowResizedNotification as String, .window, "window_resized"),
        (kAXTitleChangedNotification as String, .window, "title_changed"),
        (kAXUIElementDestroyedNotification as String, .destroy, "element_destroyed")
    ]

    /// AX notification names to register for the requested kinds.
    static func axNotificationNames(for kinds: Set<ObservedEventKind>) -> [String] {
        axMapping.filter { kinds.contains($0.kind) }.map(\.name)
    }

    /// `(kind, event)` for an AX notification name, or nil if unrecognized.
    static func classify(axNotification name: String) -> (kind: ObservedEventKind, event: String)? {
        guard let entry = axMapping.first(where: { $0.name == name }) else {
            return nil
        }
        return (entry.kind, entry.event)
    }
}

// MARK: - Event record

/// One observed UI change. Serialized as NDJSON (one compact object per line):
/// `{ ts, event, app: { pid, name }, element? }`. `kind` is carried for in-process
/// filtering but is never encoded.
struct ObservedEvent: Sendable, Equatable, Encodable {
    /// ISO8601 timestamp (with fractional seconds).
    var ts: String
    /// Category used for `--events` filtering; not serialized.
    var kind: ObservedEventKind
    /// Wire event name, e.g. "value_changed", "app_activated".
    var event: String
    var app: ResolvedApp
    var element: AXElementRecord?

    private enum CodingKeys: String, CodingKey {
        case ts
        case event
        case app
        case element
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(event, forKey: .event)
        try container.encode(app, forKey: .app)
        try container.encodeIfPresent(element, forKey: .element)
    }

    /// One compact NDJSON line (no trailing newline). Pure and unit-tested.
    func ndjsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ScreenCommanderError.metadataFailure("Could not encode observed event.")
        }
        return line
    }
}

/// Terminal line emitted when `--until` matches: `{ matched: true, element? }`.
struct ObserveMatch: Encodable {
    var matched: Bool = true
    var element: AXElementRecord?

    func ndjsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ScreenCommanderError.metadataFailure("Could not encode match result.")
        }
        return line
    }
}

// MARK: - Predicate mini-DSL

/// `--until` predicate: whitespace-joined conjunctions of `key<op>value` conditions.
/// Keys: `role`, `title`, `value`, `id`. Operators: `=` (exact), `~=` (case-insensitive
/// contains). All conditions must hold for a record to match. Pure and unit-tested.
struct ObservePredicate: Equatable, Sendable {
    struct Condition: Equatable, Sendable {
        enum Op: Equatable, Sendable {
            case equals
            case contains
        }

        enum Key: String, Equatable, Sendable, CaseIterable {
            case role
            case title
            case value
            case id
        }

        var key: Key
        var op: Op
        var expected: String
    }

    var conditions: [Condition]

    static func parse(_ raw: String) throws -> ObservePredicate {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard !tokens.isEmpty else {
            throw ScreenCommanderError.invalidArguments(
                "--until predicate is empty. Example: 'role=AXButton title~=Save'."
            )
        }

        var conditions: [Condition] = []
        for token in tokens {
            conditions.append(try parseCondition(String(token)))
        }
        return ObservePredicate(conditions: conditions)
    }

    private static func parseCondition(_ token: String) throws -> Condition {
        // `~=` must be checked before `=` since it contains one.
        let op: Condition.Op
        let separator: String
        if let range = token.range(of: "~=") {
            op = .contains
            separator = "~="
            return try makeCondition(token: token, keyPart: String(token[..<range.lowerBound]), valuePart: String(token[range.upperBound...]), op: op, separator: separator)
        } else if let range = token.range(of: "=") {
            op = .equals
            separator = "="
            return try makeCondition(token: token, keyPart: String(token[..<range.lowerBound]), valuePart: String(token[range.upperBound...]), op: op, separator: separator)
        } else {
            throw ScreenCommanderError.invalidArguments(
                "--until condition '\(token)' has no operator. Use key=value or key~=value."
            )
        }
    }

    private static func makeCondition(token: String, keyPart: String, valuePart: String, op: Condition.Op, separator: String) throws -> Condition {
        guard let key = Condition.Key(rawValue: keyPart) else {
            let valid = Condition.Key.allCases.map(\.rawValue).joined(separator: ", ")
            throw ScreenCommanderError.invalidArguments(
                "--until condition '\(token)' uses unknown key '\(keyPart)'. Valid keys: \(valid)."
            )
        }
        guard !valuePart.isEmpty else {
            throw ScreenCommanderError.invalidArguments(
                "--until condition '\(token)' has an empty value after '\(separator)'."
            )
        }
        return Condition(key: key, op: op, expected: valuePart)
    }

    /// True when every condition holds for `record`.
    func matches(_ record: AXElementRecord) -> Bool {
        conditions.allSatisfy { condition in
            let field: String
            switch condition.key {
            case .role: field = record.role
            case .title: field = record.title ?? ""
            case .value: field = record.value ?? ""
            case .id: field = record.id
            }
            switch condition.op {
            case .equals:
                return field == condition.expected
            case .contains:
                return field.lowercased().contains(condition.expected.lowercased())
            }
        }
    }

    /// First record in `records` that matches, if any (used by the initial tree scan).
    func firstMatch(in records: [AXElementRecord]) -> AXElementRecord? {
        records.first(where: matches)
    }
}

// MARK: - Observation source

/// Push source of `ObservedEvent`s for one app. Hidden behind a protocol so the engine
/// can be tested against a scripted fake instead of a live `AXObserver`.
protocol ObservationSource: Sendable {
    /// Streams events for `app` filtered to `kinds`. The stream stays open until the
    /// consuming task is cancelled (which tears the observer down via `onTermination`).
    ///
    /// Throwing so observer *setup* failures (AXObserverCreate failing, or every
    /// requested notification being rejected) surface as an error — the engine maps a
    /// clean finish to `ObserveOutcome.completed` (exit 0), which would otherwise make a
    /// dead/AX-hostile target indistinguishable from a matched/clean run.
    func events(app: ResolvedApp, kinds: Set<ObservedEventKind>) -> AsyncThrowingStream<ObservedEvent, Error>
}

/// Production `ObservationSource` backed by `AXObserverCreate` +
/// `AXObserverAddNotification`, plus NSWorkspace lifecycle notifications for `.app`.
///
/// App-wide notifications (focus/window changes) are registered on the application
/// element. `kAXValueChangedNotification` is emitted by the individual focused control,
/// not the app element, so value observation additionally (re)subscribes on the actually
/// focused element, following focus changes. The observer's run-loop source is driven on
/// a dedicated thread so the CLI's synchronous entry point stays unblocked.
final class AXObserverSource: ObservationSource {
    func events(app: ResolvedApp, kinds: Set<ObservedEventKind>) -> AsyncThrowingStream<ObservedEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = AXObserverSession(app: app, kinds: kinds, continuation: continuation)
            continuation.onTermination = { _ in
                session.stop()
            }
            session.start()
        }
    }
}

/// Owns the live AXObserver + NSWorkspace observers for a single `events(...)` call and
/// funnels callbacks into the stream continuation. Runs its AX run-loop source on a
/// dedicated thread.
private final class AXObserverSession: @unchecked Sendable {
    private let app: ResolvedApp
    private let kinds: Set<ObservedEventKind>
    private let continuation: AsyncThrowingStream<ObservedEvent, Error>.Continuation

    /// Guards all cross-thread state below: `stop()` runs on the terminating task's
    /// thread while the observer callbacks / run-loop setup run on the dedicated
    /// observer thread.
    private let lock = NSLock()
    private var observer: AXObserver?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Set by `stop()`; gates entry into `CFRunLoopRun()` so a stop that races the
    /// run-loop setup can never leave a spinning observer thread behind.
    private var stopped = false
    /// The element currently carrying a `kAXValueChangedNotification` subscription.
    /// Value changes come from the focused control, not the app element, so this follows
    /// focus.
    private var valueObservedElement: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private let workspaceQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "screencommander.workspace-observer"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let maxValueLength = 200

    init(
        app: ResolvedApp,
        kinds: Set<ObservedEventKind>,
        continuation: AsyncThrowingStream<ObservedEvent, Error>.Continuation
    ) {
        self.app = app
        self.kinds = kinds
        self.continuation = continuation
    }

    func start() {
        if kinds.contains(.app) {
            registerWorkspaceObservers()
        }

        // Register the app-wide notifications for the requested kinds. When observing
        // value changes we also need focus-change events (even if the caller didn't ask
        // for `.focus`) so we can follow focus and (re)subscribe value on the focused
        // control; those internal focus events are tracked but not emitted.
        var axNames = ObservedNotification.axNotificationNames(for: kinds)
        if kinds.contains(.value), !axNames.contains(kAXFocusedUIElementChangedNotification as String) {
            axNames.append(kAXFocusedUIElementChangedNotification as String)
        }
        guard !axNames.isEmpty else {
            return
        }

        let thread = Thread { [weak self] in
            self?.runAXLoop(notificationNames: axNames)
        }
        thread.name = "screencommander.axobserver"
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let runLoop = self.runLoop
        let tokens = workspaceTokens
        workspaceTokens.removeAll()
        observer = nil
        valueObservedElement = nil
        lock.unlock()

        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }

        if let runLoop {
            // Enqueue the stop *on* the target run loop rather than calling
            // CFRunLoopStop directly: if the loop has not yet entered CFRunLoopRun,
            // CFRunLoopStop is a no-op and the loop would then block forever. A queued
            // block is retained until the loop next runs, then stops it. WakeUp handles
            // the already-running case.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    // MARK: - AX run loop

    private func runAXLoop(notificationNames: [String]) {
        var observerRef: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let session = Unmanaged<AXObserverSession>.fromOpaque(refcon).takeUnretainedValue()
            session.handleAX(notification: notification as String, element: element)
        }

        guard AXObserverCreate(app.pid, callback, &observerRef) == .success,
              let observerRef else {
            continuation.finish(
                throwing: ScreenCommanderError.axTreeUnavailable(
                    "Could not create an accessibility observer for '\(app.name)' (pid \(app.pid)). "
                        + "The app may be exiting or may not implement accessibility."
                )
            )
            return
        }

        let appElement = AXUIElementCreateApplication(app.pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in notificationNames {
            // The internal focus tracker for value observation is best-effort; the app
            // notifications for the requested kinds must register for the stream to be
            // useful, so those drive the "usable" count.
            let error = AXObserverAddNotification(observerRef, appElement, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered {
                registered += 1
            }
        }

        // Every requested notification was rejected (e.g. .notificationUnsupported /
        // .cannotComplete): a permanently-empty stream would masquerade as a clean run,
        // so fail instead.
        guard registered > 0 else {
            continuation.finish(
                throwing: ScreenCommanderError.axTreeUnavailable(
                    "App '\(app.name)' (pid \(app.pid)) rejected every observe subscription. "
                        + "It may not support accessibility notifications."
                )
            )
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        let source = AXObserverGetRunLoopSource(observerRef)

        lock.lock()
        if stopped {
            // stop() already ran before we got here — don't enter a run loop nobody will
            // stop.
            lock.unlock()
            continuation.finish()
            return
        }
        self.observer = observerRef
        self.runLoop = currentRunLoop
        lock.unlock()

        // Subscribe value-changed on the initially focused control.
        if kinds.contains(.value) {
            subscribeFocusedValue()
        }

        CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
        CFRunLoopRun()

        // Run loop stopped (stop() called): finish the stream.
        continuation.finish()
    }

    private func handleAX(notification: String, element: AXUIElement) {
        guard let classified = ObservedNotification.classify(axNotification: notification) else {
            return
        }

        // Follow focus for value observation regardless of whether `.focus` was
        // requested for emission.
        if classified.event == "focus_changed", kinds.contains(.value) {
            subscribeFocusedValue()
        }

        guard kinds.contains(classified.kind) else {
            return
        }
        let record = Self.makeRecord(element: AXElement(raw: element), maxValueLength: maxValueLength)
        continuation.yield(
            ObservedEvent(
                ts: Self.timestamp(),
                kind: classified.kind,
                event: classified.event,
                app: app,
                element: record
            )
        )
    }

    /// (Re)subscribes `kAXValueChangedNotification` on the app's currently focused
    /// element, removing the previous subscription. No-op once stopped.
    private func subscribeFocusedValue() {
        lock.lock()
        guard let observer = self.observer, !stopped else {
            lock.unlock()
            return
        }
        lock.unlock()

        let appElement = AXUIElementCreateApplication(app.pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return
        }
        let focused = focusedRef as! AXUIElement

        lock.lock()
        let previous = valueObservedElement
        if let previous, CFEqual(previous, focused) {
            lock.unlock()
            return
        }
        valueObservedElement = focused
        lock.unlock()

        if let previous {
            AXObserverRemoveNotification(observer, previous, kAXValueChangedNotification as CFString)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, focused, kAXValueChangedNotification as CFString, refcon)
    }

    // MARK: - NSWorkspace lifecycle

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didLaunchApplicationNotification, "app_launched"),
            (NSWorkspace.didActivateApplicationNotification, "app_activated"),
            (NSWorkspace.didTerminateApplicationNotification, "app_terminated")
        ]
        var tokens: [NSObjectProtocol] = []
        for (name, eventName) in events {
            let token = center.addObserver(forName: name, object: nil, queue: workspaceQueue) { [weak self] note in
                self?.handleWorkspace(eventName: eventName, note: note)
            }
            tokens.append(token)
        }
        lock.lock()
        workspaceTokens.append(contentsOf: tokens)
        lock.unlock()
    }

    private func handleWorkspace(eventName: String, note: Notification) {
        guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              running.processIdentifier == app.pid else {
            return
        }
        continuation.yield(
            ObservedEvent(
                ts: Self.timestamp(),
                kind: .app,
                event: eventName,
                app: app,
                element: nil
            )
        )
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Minimal record for an observed element (no id path / pixel bounds — the observer
    /// reports live elements without a stable tree position).
    static func makeRecord(element: AXElement, maxValueLength: Int) -> AXElementRecord {
        var value = element.value
        var valueTruncated: Bool?
        if let fullValue = value {
            let (shortened, truncated) = AXElementRecord.truncatedValue(fullValue, maxLength: maxValueLength)
            value = shortened
            if truncated {
                valueTruncated = true
            }
        }
        return AXElementRecord(
            id: "",
            role: element.role ?? "AXUnknown",
            subrole: element.subrole,
            title: element.title,
            value: value,
            valueTruncated: valueTruncated,
            description: element.axDescription,
            enabled: element.isEnabled ?? true,
            focused: element.isFocused,
            actions: element.actionNames,
            boundsPoints: element.frame.map(RectD.init),
            boundsPixels: nil
        )
    }
}
