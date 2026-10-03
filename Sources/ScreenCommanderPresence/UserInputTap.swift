import CoreGraphics
import Foundation

/// Control-Option-Command-Period stops every session until `resume`.
public enum AbortChord {
    /// kVK_ANSI_Period.
    public static let keyCode: Int64 = 47
    public static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    /// Exact match on Control, Option, and Command. Shift turns it off so a
    /// different shortcut does not abort by accident. Caps Lock and Fn are ignored.
    public static func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        return keyCode == Self.keyCode && relevant == modifiers
    }
}

/// One event seen by the tap.
struct ObservedInput {
    /// Source pid of the event, 0 for hardware input.
    var sourcePID: pid_t
    var kind: UserInputKind
    var isAbortChord: Bool
    /// The window under the pointer for mouse and gesture events, when the event says.
    var windowUnderPointer: UInt32?
}

/// Listen-only session event tap for every kind of user input: keys, modifiers,
/// buttons, pointer motion, scrolls, and trackpad gestures. It never modifies
/// or blocks events. Creating it needs Accessibility or Input Monitoring.
/// Without either, `start()` returns false and the presence process reports
/// `tapAvailable: false`.
final class UserInputTap {
    typealias Handler = (ObservedInput) -> Void

    /// Raw `CGEventType` values the tap listens to. Gesture types have no
    /// `CGEventType` case, so they are listed by number: 18 rotate, 19 and 20
    /// begin and end gesture, 29 gesture (swipes between Spaces, Mission Control,
    /// and app switching arrive as these), 30 magnify, 31 swipe, 32 smart magnify,
    /// 34 pressure.
    static let observedTypes: [UInt32] = [
        CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
        CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue,
        CGEventType.rightMouseDown.rawValue, CGEventType.rightMouseUp.rawValue,
        CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue,
        CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDragged.rawValue,
        CGEventType.rightMouseDragged.rawValue, CGEventType.otherMouseDragged.rawValue,
        CGEventType.scrollWheel.rawValue,
        18, 19, 20, 29, 30, 31, 32, 34,
    ]

    /// Raw types whose HID idle time the window server tracks for hardware
    /// input alone. `kCGAnyInputEventType`, and types it does not track (such as
    /// 32 and 34), report the system's overall idle time instead, which the
    /// events screencommander posts to an app reset too, so they would make every
    /// agent action look like the user's.
    static let hidIdleTypes: [UInt32] = [
        CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
        CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue,
        CGEventType.rightMouseDown.rawValue, CGEventType.rightMouseUp.rawValue,
        CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue,
        CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDragged.rawValue,
        CGEventType.rightMouseDragged.rawValue, CGEventType.otherMouseDragged.rawValue,
        CGEventType.scrollWheel.rawValue,
        29, 30,
    ]

    /// Key presses, clicks, scrolls, and gestures say which app the user works in.
    static func kind(ofRawType type: UInt32) -> UserInputKind {
        switch type {
        case CGEventType.keyDown.rawValue,
             CGEventType.leftMouseDown.rawValue, CGEventType.rightMouseDown.rawValue, CGEventType.otherMouseDown.rawValue,
             CGEventType.scrollWheel.rawValue,
             18, 29, 30, 31, 32:
            return .deliberate
        default:
            return .ambient
        }
    }

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isAvailable: Bool {
        tap != nil
    }

    /// Installs the tap on the current run loop. Returns false when the system refuses.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else {
            return true
        }
        let mask = Self.observedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: userInputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        default:
            break
        }
        let raw = type.rawValue
        let kind = Self.kind(ofRawType: raw)
        var isAbort = false
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            isAbort = AbortChord.matches(keyCode: keyCode, flags: event.flags)
        }
        var window: UInt32?
        if kind == .deliberate, type != .keyDown {
            let value = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            window = value > 0 ? UInt32(truncatingIfNeeded: value) : nil
        }
        handler(ObservedInput(
            sourcePID: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID)),
            kind: kind,
            isAbortChord: isAbort,
            windowUnderPointer: window
        ))
    }
}

private func userInputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<UserInputTap>.fromOpaque(userInfo).takeUnretainedValue().receive(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
