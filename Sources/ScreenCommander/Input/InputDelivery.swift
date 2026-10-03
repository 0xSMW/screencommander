import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A window that background input is addressed to.
struct InputWindowTarget: Equatable, Sendable {
    var pid: pid_t
    var windowID: CGWindowID
    /// Window frame in global top-left-origin points.
    var bounds: CGRect
    /// False when the window exists but is not on screen: minimized, its app hidden,
    /// on another Space, or shown only as a Stage Manager thumbnail. Window-addressed
    /// mouse events cannot reach such a window.
    var isOnScreen = true
    /// True for a window that Stage Manager shows as a thumbnail in its strip. It is
    /// not on screen at its own frame, so mouse events are refused, but it can still
    /// be made key for keyboard input. `bounds` is the window's own frame.
    var isStageManagerThumbnail = false

    /// Keyboard delivery can address the window: it is on screen, or a Stage Manager
    /// thumbnail, which still takes key events and can be made key.
    var acceptsKeyboard: Bool {
        isOnScreen || isStageManagerThumbnail
    }
    /// The window server layer: 0 for document windows, higher for panels, pop-up
    /// menus, the Dock, and the menu bar, negative for the desktop.
    var layer = 0
    /// The owning process's name as the window server reports it.
    var ownerName: String? = nil
    /// Keyboard input must reach this window, because the caller named it or it
    /// holds the target element. Delivery makes it key in its app first, without
    /// activating the app, and fails rather than sending keys to another window.
    var requiresKeyFocus = false

    /// Owned by the window server itself, such as the menu bar. No process takes
    /// events addressed to it.
    var isWindowServerOwned: Bool {
        ownerName == "Window Server"
    }

    /// An open pop-up or context menu. A menu chooses an item only from the real
    /// pointer: a click posted to its app closes it without choosing anything.
    var isPopUpMenu: Bool {
        layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    /// The same window, marked so keys must reach it.
    func requiringKeyFocus() -> InputWindowTarget {
        var target = self
        target.requiresKeyFocus = true
        return target
    }

    /// Names the window for a refusal: owner, ID, and layer.
    var refusalDescription: String {
        "window \(windowID)\(ownerName.map { " of '\($0)'" } ?? "") (pid \(pid), layer \(layer))"
    }
}

/// Stage Manager draws the windows of inactive stages as small thumbnails in its
/// strip, and `CGWindowListCopyWindowInfo` reports them as on screen at the
/// thumbnail's bounds. The window's own frame (from the window server) is unchanged,
/// so a reported size well below the frame's means a thumbnail.
enum StageManagerThumbnail {
    static func isThumbnail(reported: CGRect, frame: CGRect?) -> Bool {
        guard let frame, frame.width > 0, frame.height > 0 else {
            return false
        }
        return reported.width < frame.width * 0.9 || reported.height < frame.height * 0.9
    }
}

/// Where synthesized events are posted.
///
/// - `global`: `.cghidEventTap`. Moves the real cursor and types into the frontmost app.
///   Only used with `--foreground`.
/// - `pid`: `CGEventPostToPid` with no window stamping (keyboard to an app with no
///   known window).
/// - `window`: `CGEventPostToPid`, mouse events stamped with the window ID, target pid,
///   and a window-local location.
/// - `focusAssisted`: a focus-without-raise record to the target, a key-window
///   primer (a click addressed to the window at a point outside its frame), the same
///   events as `window`, then a lost-focus record to the target. No other process
///   receives anything. `authenticatedKeyboard` posts key events through
///   `SLEventPostToPid` with an authentication message (Chromium/Electron).
enum InputEventDestination: Equatable, Sendable {
    case global
    case pid(pid_t)
    case window(InputWindowTarget)
    case focusAssisted(InputWindowTarget, authenticatedKeyboard: Bool)

    var targetPid: pid_t? {
        switch self {
        case .global:
            return nil
        case .pid(let pid):
            return pid
        case .window(let target), .focusAssisted(let target, _):
            return target.pid
        }
    }

    var windowTarget: InputWindowTarget? {
        switch self {
        case .global, .pid:
            return nil
        case .window(let target), .focusAssisted(let target, _):
            return target
        }
    }
}

typealias MouseEventDestination = InputEventDestination

enum InputEventKind: Sendable {
    case mouse
    case keyboard
}

/// Posts events the controllers build. The only place input leaves the process, so
/// tests can record exactly what would have been delivered and where.
protocol InputEventPosting {
    /// Runs once per action before its first event. `focusAssisted` tells the target
    /// here that it is active and makes its window key. A window that
    /// `requiresKeyFocus` is checked here: it must be key, or be made key, or this
    /// throws before any event goes out. A `prepare` that throws leaves nothing to
    /// undo, so `finish` is not called for it.
    func prepare(_ destination: InputEventDestination) throws
    func post(_ event: CGEvent, to destination: InputEventDestination, kind: InputEventKind)
    /// Runs once after the action's last event whenever `prepare` succeeded, also
    /// when delivery failed. `focusAssisted` tells the target here that it lost focus
    /// again, so its own state matches the real one.
    func finish(_ destination: InputEventDestination)
}

/// The focus-record calls `focusAssisted` makes, behind a seam so tests can check
/// that every fake focus is undone.
protocol FocusRecordPosting {
    /// True only when every symbol needed both to post a focus record and to undo
    /// it resolves: the record poster, the pid lookup, and the front-process check.
    var isAvailable: Bool { get }
    /// Nil when the lookup fails.
    func isFrontProcess(_ pid: pid_t) -> Bool?
    func postFocusRecord(targetPid: pid_t, windowID: CGWindowID, focused: Bool) -> Bool
}

struct LiveFocusRecords: FocusRecordPosting {
    var isAvailable: Bool { PrivateAPI.canPostFocusRecords }

    func isFrontProcess(_ pid: pid_t) -> Bool? {
        PrivateAPI.isFrontProcess(pid)
    }

    func postFocusRecord(targetPid: pid_t, windowID: CGWindowID, focused: Bool) -> Bool {
        PrivateAPI.postFocusRecord(targetPid: targetPid, windowID: windowID, focused: focused)
    }
}

/// Which window of an app is key: the one its key events go to.
protocol KeyWindowReading {
    /// The app's key window as accessibility reports it (`AXFocusedWindow`). An
    /// AppKit app that is not active still reports the window that is key within
    /// it. Nil when there is none or accessibility cannot say.
    func keyWindowID(pid: pid_t) -> CGWindowID?
}

struct AXKeyWindowReader: KeyWindowReading {
    func keyWindowID(pid: pid_t) -> CGWindowID? {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(seconds: 0.3)
        guard let window = app.focusedWindow else {
            return nil
        }
        window.setMessagingTimeout(seconds: 0.3)
        return window.windowID
    }
}

/// The private-state source every synthesized event comes from. Modifiers the user
/// holds never leak in, and posting never suppresses the user's own hardware input:
/// the default source suppresses local mouse and keyboard events for 0.25 s after
/// each synthetic event.
enum SyntheticEventSource {
    static let permitAllLocalEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]

    static func make() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else {
            return nil
        }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(permitAllLocalEvents, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(permitAllLocalEvents, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }
}

/// Background destinations post only to the target pid. Nothing is ever posted to
/// another process, including the app the user is working in.
///
/// `prepare` and `finish` pair up: a focus record sent in `prepare` is undone in
/// `finish`, or in `prepare` itself when it fails after sending one. Focus records
/// are sent only when every symbol needed to undo them resolves.
final class LiveInputEventPoster: InputEventPosting {
    private let focusRecords: FocusRecordPosting
    private let keyWindows: KeyWindowReading
    private let primer: (InputWindowTarget, InputEventPosting) throws -> Void
    private let deliver: (CGEvent, InputEventDestination, InputEventKind) -> Void
    private let pause: (useconds_t) -> Void
    /// Focus records sent by `prepare` and not yet undone, per target window.
    private var outstanding: [String: Int] = [:]
    private let lock = NSLock()

    init(
        focusRecords: FocusRecordPosting = LiveFocusRecords(),
        keyWindows: KeyWindowReading = AXKeyWindowReader(),
        primer: @escaping (InputWindowTarget, InputEventPosting) throws -> Void = KeyWindowPrimer.prime,
        deliver: @escaping (CGEvent, InputEventDestination, InputEventKind) -> Void = LiveInputEventPoster.postLive,
        pause: @escaping (useconds_t) -> Void = { usleep($0) }
    ) {
        self.focusRecords = focusRecords
        self.keyWindows = keyWindows
        self.primer = primer
        self.deliver = deliver
        self.pause = pause
    }

    func prepare(_ destination: InputEventDestination) throws {
        switch destination {
        case .window(let target) where target.requiresKeyFocus:
            // Key events posted to the pid go to the app's key window, and plain
            // window delivery has no way to change which one that is.
            let key = keyWindows.keyWindowID(pid: target.pid)
            guard key == target.windowID else {
                throw Self.notKey(target, key: key, detail: "Keys posted to the app go to its key window, and the window tier cannot change it.")
            }
        case .focusAssisted(let target, _):
            try prepareFocusAssisted(target)
        default:
            return
        }
    }

    private func prepareFocusAssisted(_ target: InputWindowTarget) throws {
        guard focusRecords.isAvailable else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "The focus-record symbols focusAssisted needs to make a window key and undo it are missing (see 'doctor')."
            )
        }
        guard let front = focusRecords.isFrontProcess(target.pid) else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "Could not tell whether pid \(target.pid) is the frontmost app, so no focus record was sent."
            )
        }
        // A target that really is frontmost already has focus: nothing to fake.
        if !front {
            guard focusRecords.postFocusRecord(targetPid: target.pid, windowID: target.windowID, focused: true) else {
                throw ScreenCommanderError.backgroundDeliveryUnavailable(
                    "Could not post a focus record to pid \(target.pid) (window \(target.windowID))."
                )
            }
            // Give AppKit a turn to process the focus change before input arrives.
            pause(50_000)
        }
        do {
            // The focus record makes the app active but leaves it without a key
            // window. AppKit sends menu commands that have no fixed target, and views
            // their shortcuts, through the key window, and Chromium reads keys and the
            // first click only in a key window. A mouse-down while the app believes it
            // is active makes the window key. A frontmost app already has a key
            // window, and is primed only when keys must reach a different one.
            if !front || (target.requiresKeyFocus && keyWindows.keyWindowID(pid: target.pid) != target.windowID) {
                try primer(target, self)
            }
            if target.requiresKeyFocus, let key = keyWindows.keyWindowID(pid: target.pid), key != target.windowID {
                throw Self.notKey(target, key: key, detail: "It did not become key after the focus record and key-window click.")
            }
        } catch {
            if !front {
                undoFocusRecord(target)
            }
            throw error
        }
        if !front {
            lock.lock()
            outstanding[Self.key(target), default: 0] += 1
            lock.unlock()
        }
    }

    func finish(_ destination: InputEventDestination) {
        guard case .focusAssisted(let target, _) = destination else {
            return
        }
        lock.lock()
        let count = outstanding[Self.key(target), default: 0]
        if count > 1 {
            outstanding[Self.key(target)] = count - 1
        } else {
            outstanding[Self.key(target)] = nil
        }
        lock.unlock()
        guard count > 0 else {
            return
        }
        // Let the target handle the input before it hears it lost focus.
        pause(30_000)
        undoFocusRecord(target)
    }

    /// Tells the target it lost focus, unless it became the real frontmost app in
    /// the meantime and so holds focus for real. A failed lookup still undoes.
    private func undoFocusRecord(_ target: InputWindowTarget) {
        guard focusRecords.isFrontProcess(target.pid) != true else {
            return
        }
        _ = focusRecords.postFocusRecord(targetPid: target.pid, windowID: target.windowID, focused: false)
    }

    func post(_ event: CGEvent, to destination: InputEventDestination, kind: InputEventKind) {
        deliver(event, destination, kind)
    }

    static func postLive(_ event: CGEvent, to destination: InputEventDestination, kind: InputEventKind) {
        switch destination {
        case .global:
            event.post(tap: .cghidEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        case .window(let target):
            event.postToPid(target.pid)
        case .focusAssisted(let target, let authenticatedKeyboard):
            if kind == .keyboard, authenticatedKeyboard, PrivateAPI.postAuthenticated(event, toPid: target.pid) {
                return
            }
            event.postToPid(target.pid)
        }
    }

    private static func key(_ target: InputWindowTarget) -> String {
        "\(target.pid):\(target.windowID)"
    }

    private static func notKey(_ target: InputWindowTarget, key: CGWindowID?, detail: String) -> ScreenCommanderError {
        let current = key.map { "window \($0) is" } ?? "no window could be read as"
        return .backgroundDeliveryUnavailable(
            "Keys must reach window \(target.windowID) of pid \(target.pid), but \(current) key in that app. \(detail) "
                + "No keys were sent."
        )
    }
}

/// Stamps mouse events for window-addressed delivery: button, click state, subtype,
/// the window under the pointer, the target pid, and a window-local location.
enum WindowEventStamper {
    static let mouseSubtypeField = CGEventField(rawValue: 7)!
    /// The event record's window number; AppKit reads it into `NSEvent.windowNumber`.
    static let windowNumberField = CGEventField(rawValue: 51)!
    static let windowUnderPointerField = CGEventField(rawValue: 91)!
    static let windowThatCanHandleField = CGEventField(rawValue: 92)!
    static let targetPidField = CGEventField(rawValue: 40)!

    /// `NSEventSubtypeTouch`, the subtype cua stamps on background clicks.
    static let mouseSubtype: Int64 = 3

    static func stamp(
        _ event: CGEvent,
        target: InputWindowTarget,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int
    ) throws {
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(mouseSubtypeField, value: mouseSubtype)
        event.setIntegerValueField(windowNumberField, value: Int64(target.windowID))
        event.setIntegerValueField(windowUnderPointerField, value: Int64(target.windowID))
        event.setIntegerValueField(windowThatCanHandleField, value: Int64(target.windowID))
        event.setIntegerValueField(targetPidField, value: Int64(target.pid))

        let local = CGPoint(x: point.x - target.bounds.minX, y: point.y - target.bounds.minY)
        guard PrivateAPI.setWindowLocation(event, local) else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "CGEventSetWindowLocation is unavailable; window-addressed mouse delivery is not possible."
            )
        }
    }
}

/// Makes the target's window key inside a `focusAssisted` action.
///
/// It sends one left click addressed to the window (window number, pid, and a
/// window-local location) at a point outside the window's frame. AppKit makes a
/// window key on a mouse-down while the app believes it is active, and a point
/// outside the frame hits no view, title bar, or web content, so the click has no
/// other effect. It goes to the target pid only.
enum KeyWindowPrimer {
    /// Window-local point, above and to the left of the window's top-left corner.
    static let localPoint = CGPoint(x: -20, y: -20)
    static let pressMicroseconds: useconds_t = 20_000
    /// AppKit makes the window key on the mouse-down; the settle lets the target
    /// finish that and revalidate its menus before the action's input arrives.
    static let settleMicroseconds: useconds_t = 80_000

    /// The global point the primer's events carry for `target`.
    static func globalPoint(for target: InputWindowTarget) -> CGPoint {
        CGPoint(x: target.bounds.minX + localPoint.x, y: target.bounds.minY + localPoint.y)
    }

    static func events(for target: InputWindowTarget, source: CGEventSource?) throws -> [CGEvent] {
        let point = globalPoint(for: target)
        return try [CGEventType.leftMouseDown, .leftMouseUp].map { type in
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw ScreenCommanderError.inputSynthesisFailed("Could not create the key-window primer event.")
            }
            try WindowEventStamper.stamp(event, target: target, point: point, button: .left, clickState: 1)
            return event
        }
    }

    static func prime(_ target: InputWindowTarget, poster: InputEventPosting) throws {
        let events = try events(for: target, source: SyntheticEventSource.make())
        for (index, event) in events.enumerated() {
            if index > 0 {
                usleep(pressMicroseconds)
            }
            poster.post(event, to: .window(target), kind: .mouse)
        }
        usleep(settleMicroseconds)
    }
}

// MARK: - Window lookup

/// Window lookup for background targeting, front-to-back.
protocol WindowLocating {
    /// Any window by ID, on screen or not. `isOnScreen` says which.
    func window(id: CGWindowID) -> InputWindowTarget?
    /// The topmost visible window containing `point` at any layer, front to back:
    /// pop-up menus, panels, the Dock, the menu bar, document windows, and the
    /// desktop. With `pid`, only that process's windows count. A Stage Manager
    /// thumbnail is matched at its thumbnail's bounds and comes back with
    /// `isStageManagerThumbnail`. The agent cursor's own windows never count.
    func topWindow(at point: CGPoint, pid: pid_t?) -> InputWindowTarget?
    /// The pid's frontmost on-screen normal-layer window.
    func frontWindow(pid: pid_t) -> InputWindowTarget?
    /// The pid's minimized windows, which are never on screen.
    func minimizedWindowIDs(pid: pid_t) -> [CGWindowID]
    /// The pid's windows that exist but are not on screen (minimized, or the app is
    /// hidden), minimized ones first.
    func offScreenWindowIDs(pid: pid_t) -> [CGWindowID]
}

extension WindowLocating {
    func minimizedWindowIDs(pid: pid_t) -> [CGWindowID] { [] }
    func offScreenWindowIDs(pid: pid_t) -> [CGWindowID] { minimizedWindowIDs(pid: pid) }
}

/// `CGWindowListCopyWindowInfo` returns windows front-to-back and needs no Screen
/// Recording grant for ids, owners, layers, and bounds.
struct CGWindowLocator: WindowLocating {
    func window(id: CGWindowID) -> InputWindowTarget? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        if let onScreen = list.lazy.compactMap({ Self.target(from: $0, requireNormalLayer: false) }).first(where: { $0.windowID == id }) {
            return onScreen
        }
        // A window that is minimized, hidden with its app, or on another Space only
        // appears in the full list.
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.lazy.compactMap { Self.target(from: $0, requireNormalLayer: false) }.first { $0.windowID == id }
    }

    func topWindow(at point: CGPoint, pid: pid_t?) -> InputWindowTarget? {
        // Desktop elements are included: the desktop is what a click on an empty
        // part of the screen reaches.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self.topWindow(in: list, at: point, pid: pid)
    }

    /// The hit test over a front-to-back window list, at every layer. `frame` reads
    /// a window's own frame for Stage Manager thumbnail detection.
    static func topWindow(
        in list: [[String: Any]],
        at point: CGPoint,
        pid: pid_t?,
        frame: (CGWindowID) -> CGRect? = PrivateAPI.windowFrame
    ) -> InputWindowTarget? {
        for info in list where !isAgentCursor(info) {
            guard let reported = hitBounds(info), reported.contains(point),
                  let target = target(from: info, requireNormalLayer: false, frame: frame),
                  pid == nil || target.pid == pid else {
                continue
            }
            return target
        }
        return nil
    }

    /// The on-screen bounds a window is hit at, nil for a window that takes no
    /// clicks there: fully transparent, or a sliver of a point or less.
    static func hitBounds(_ info: [String: Any]) -> CGRect? {
        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0, bounds.width > 1, bounds.height > 1 else {
            return nil
        }
        return bounds
    }

    /// The pid's frontmost window on screen, else its frontmost Stage Manager
    /// thumbnail, which keyboard input can still use.
    func frontWindow(pid: pid_t) -> InputWindowTarget? {
        let windows = onScreenNormalWindows().filter { $0.pid == pid }
        return windows.first(where: \.isOnScreen) ?? windows.first
    }

    func minimizedWindowIDs(pid: pid_t) -> [CGWindowID] {
        MinimizedWindows.ids(pid: pid)
    }

    func offScreenWindowIDs(pid: pid_t) -> [CGWindowID] {
        let onScreen = Set(onScreenNormalWindows().filter { $0.pid == pid && $0.isOnScreen }.map(\.windowID))
        return MinimizedWindows.offScreenIDs(pid: pid, onScreen: onScreen)
    }

    private func onScreenNormalWindows() -> [InputWindowTarget] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            Self.isAgentCursor(info) ? nil : Self.target(from: info, requireNormalLayer: true)
        }
    }

    /// The agent cursor sits directly above the window it points at, at that window's
    /// level, so a hit test at the point it is parked on would otherwise find it. The
    /// title needs Screen Recording; the owner name (the presence process runs this
    /// same binary, and draws nothing else) does not.
    static func isAgentCursor(_ info: [String: Any]) -> Bool {
        (info[kCGWindowName as String] as? String) == OverlayExclusion.cursorWindowTitle
            || (info[kCGWindowOwnerName as String] as? String) == "screencommander"
    }

    private static func target(
        from info: [String: Any],
        requireNormalLayer: Bool,
        frame readFrame: (CGWindowID) -> CGRect? = PrivateAPI.windowFrame
    ) -> InputWindowTarget? {
        guard let number = info[kCGWindowNumber as String] as? NSNumber,
              let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        if requireNormalLayer {
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0, bounds.width > 1, bounds.height > 1 else {
                return nil
            }
        }
        let ownerName = info[kCGWindowOwnerName as String] as? String
        if isOnScreen, layer == 0, let frame = readFrame(number.uint32Value),
           StageManagerThumbnail.isThumbnail(reported: bounds, frame: frame) {
            return InputWindowTarget(
                pid: pid.int32Value, windowID: number.uint32Value, bounds: frame,
                isOnScreen: false, isStageManagerThumbnail: true, layer: layer, ownerName: ownerName
            )
        }
        return InputWindowTarget(
            pid: pid.int32Value, windowID: number.uint32Value, bounds: bounds, isOnScreen: isOnScreen,
            layer: layer, ownerName: ownerName
        )
    }
}

// MARK: - Delivery capabilities and per-app tier choice

/// Which private-API-backed tiers this process can use. A missing symbol disables
/// the tier that needs it.
struct DeliveryCapabilities: Equatable, Sendable {
    /// `CGEventSetWindowLocation`: window-addressed mouse events.
    var windowLocation: Bool
    /// `SLPSPostEventRecordTo`, `GetProcessForPID`, and `_SLPSGetFrontProcess`:
    /// focus-without-raise records and their undo.
    var focusRecords: Bool
    /// `SLEventPostToPid` + authentication message.
    var authenticatedPost: Bool

    static let all = DeliveryCapabilities(windowLocation: true, focusRecords: true, authenticatedPost: true)

    static func live() -> DeliveryCapabilities {
        DeliveryCapabilities(
            windowLocation: PrivateAPI.canSetWindowLocation,
            focusRecords: PrivateAPI.canPostFocusRecords,
            authenticatedPost: PrivateAPI.canPostAuthenticatedEvents
        )
    }
}

// MARK: - Focus receipts

struct FocusSample: Equatable, Sendable {
    var frontmostPid: pid_t?
    var frontmostBundleID: String?
    /// The hardware cursor location in global points.
    var cursor: CGPoint?
    /// Identity of the frontmost app's focused window: its window ID when AX maps it
    /// to one, else a hash of the AX element. Never its title or contents.
    var focusedWindow: String?
    /// Identity of the frontmost app's focused UI element: its role and a hash of
    /// the AX element. Never its value.
    var focusedElement: String?
    /// When the sample was taken. The receipt asks the focus guard about restores
    /// since then. Not part of equality.
    var takenAt: Date

    init(
        frontmostPid: pid_t?,
        frontmostBundleID: String?,
        cursor: CGPoint?,
        focusedWindow: String? = nil,
        focusedElement: String? = nil,
        takenAt: Date = Date()
    ) {
        self.frontmostPid = frontmostPid
        self.frontmostBundleID = frontmostBundleID
        self.cursor = cursor
        self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement
        self.takenAt = takenAt
    }

    static func == (lhs: FocusSample, rhs: FocusSample) -> Bool {
        lhs.frontmostPid == rhs.frontmostPid
            && lhs.frontmostBundleID == rhs.frontmostBundleID
            && lhs.cursor == rhs.cursor
            && lhs.focusedWindow == rhs.focusedWindow
            && lhs.focusedElement == rhs.focusedElement
    }
}

/// Samples the frontmost app, its focused window and element, and the cursor
/// around an action. Injected so tests can script what the receipt observes.
protocol FocusSampling {
    func sample() -> FocusSample
    /// The short wait between delivery and the after-sample.
    func settle()
}

struct LiveFocusSampler: FocusSampling {
    var settleMicroseconds: useconds_t = 60_000

    func sample() -> FocusSample {
        let app = FrontmostApp.current()
        var focusedWindow: String?
        var focusedElement: String?
        if let pid = app?.pid {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.2)
            if let window = Self.copyElement(element, kAXFocusedWindowAttribute) {
                if let mapped = PrivateAPI.axGetWindow(window), mapped.error == .success, mapped.windowID != 0 {
                    focusedWindow = "window:\(mapped.windowID)"
                } else {
                    focusedWindow = "ax:\(String(CFHash(window), radix: 16))"
                }
            }
            if let focused = Self.copyElement(element, kAXFocusedUIElementAttribute) {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
                focusedElement = "\((role as? String) ?? "AXUnknown"):\(String(CFHash(focused), radix: 16))"
            }
        }
        return FocusSample(
            frontmostPid: app?.pid,
            frontmostBundleID: app?.bundleID ?? app?.name,
            cursor: CGEvent(source: nil)?.location,
            focusedWindow: focusedWindow,
            focusedElement: focusedElement
        )
    }

    func settle() {
        usleep(settleMicroseconds)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

/// What the engine observed about focus and the cursor across one action.
struct FocusReceipt: Codable, Sendable, Equatable {
    var preserved: Bool
    var frontmostBefore: String?
    var frontmostAfter: String?
    var focusedWindowBefore: String?
    var focusedWindowAfter: String?
    var focusedElementBefore: String?
    var focusedElementAfter: String?
    var cursorMoved: Bool
    /// True when the presence focus guard put the frontmost app back during the
    /// action, after the target took focus. `preserved` is then false, even though
    /// the after-sample matches. Absent when presence did not take part or could not
    /// say.
    var guardRestored: Bool?

    init(
        preserved: Bool,
        frontmostBefore: String?,
        frontmostAfter: String?,
        focusedWindowBefore: String? = nil,
        focusedWindowAfter: String? = nil,
        focusedElementBefore: String? = nil,
        focusedElementAfter: String? = nil,
        cursorMoved: Bool,
        guardRestored: Bool? = nil
    ) {
        self.preserved = preserved
        self.frontmostBefore = frontmostBefore
        self.frontmostAfter = frontmostAfter
        self.focusedWindowBefore = focusedWindowBefore
        self.focusedWindowAfter = focusedWindowAfter
        self.focusedElementBefore = focusedElementBefore
        self.focusedElementAfter = focusedElementAfter
        self.cursorMoved = cursorMoved
        self.guardRestored = guardRestored
    }

    /// `preserved` is false when the frontmost app, its focused window, or its
    /// focused element changed. A window or element that could only be read on one
    /// side (an AX timeout) is not counted as a change. The cursor never counts.
    ///
    /// `cursorMoved` means this action moved the hardware cursor. Only global
    /// delivery (`--foreground`) posts through the HID tap, so for every other tier
    /// a changed position can only be the user's own mouse and reads false.
    init(before: FocusSample, after: FocusSample, deliveredGlobally: Bool = false) {
        let samePid = before.frontmostPid == after.frontmostPid
        let sameBundle = before.frontmostBundleID == after.frontmostBundleID
        var cursorMoved = false
        if deliveredGlobally, let start = before.cursor, let end = after.cursor {
            cursorMoved = hypot(end.x - start.x, end.y - start.y) > 0.5
        }
        self.init(
            preserved: samePid && sameBundle
                && Self.unchanged(before.focusedWindow, after.focusedWindow)
                && Self.unchanged(before.focusedElement, after.focusedElement),
            frontmostBefore: before.frontmostBundleID,
            frontmostAfter: after.frontmostBundleID,
            focusedWindowBefore: before.focusedWindow,
            focusedWindowAfter: after.focusedWindow,
            focusedElementBefore: before.focusedElement,
            focusedElementAfter: after.focusedElement,
            cursorMoved: cursorMoved
        )
    }

    private static func unchanged(_ before: String?, _ after: String?) -> Bool {
        guard let before, let after else {
            return true
        }
        return before == after
    }
}

/// `verified` on action results: `true`/`false` when the engine re-read AX state
/// after delivery, `"unknown"` when it could not check (coordinate actions, keys).
enum ActionVerification: Codable, Sendable, Equatable {
    case checked(Bool)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .checked(value)
        } else {
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .checked(let value):
            try container.encode(value)
        case .unknown:
            try container.encode("unknown")
        }
    }
}
