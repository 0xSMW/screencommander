import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Every private symbol screencommander uses, resolved at runtime with `dlsym`.
///
/// Nothing here is linked, so a symbol Apple removes or renames shows up as
/// `isAvailable == false` (reported by `doctor`) and the delivery tier that needs it
/// is skipped. No call site may assume a symbol exists.
enum PrivateAPI {
    struct SymbolStatus: Codable, Sendable, Equatable {
        var name: String
        var available: Bool
        /// The delivery tier or feature that needs this symbol.
        var usedBy: String
    }

    // MARK: - Function signatures

    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthenticationMessageFn = @convention(c) (CGEvent, UnsafeRawPointer) -> Void
    private typealias PostEventRecordToFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessPIDFn = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias HWCaptureWindowListFn = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias GetWindowBoundsFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias AuthMessageFactoryFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> Unmanaged<AnyObject>?

    /// `ProcessSerialNumber` layout (two 32-bit halves); declared locally because the
    /// Carbon process APIs that take it are unavailable to Swift.
    private struct ProcessSerial: Equatable {
        var high: UInt32 = 0
        var low: UInt32 = 0
    }

    // MARK: - Resolution

    /// SkyLight is not loaded into a plain CLI process until something asks for it.
    private static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        _ = skyLightHandle
        // RTLD_DEFAULT: search every image loaded in the process.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    private static let setWindowLocationFn = symbol("CGEventSetWindowLocation", as: SetWindowLocationFn.self)
    private static let slEventPostToPidFn = symbol("SLEventPostToPid", as: PostToPidFn.self)
    private static let slEventSetAuthenticationMessageFn = symbol(
        "SLEventSetAuthenticationMessage", as: SetAuthenticationMessageFn.self
    )
    private static let postEventRecordToFn = symbol("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let getFrontProcessFn = symbol("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
    private static let getProcessForPIDFn = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let getProcessPIDFn = symbol("GetProcessPID", as: GetProcessPIDFn.self)
    private static let axGetWindowFn = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let mainConnectionIDFn = symbol("SLSMainConnectionID", as: MainConnectionIDFn.self)
        ?? symbol("CGSMainConnectionID", as: MainConnectionIDFn.self)
    private static let hwCaptureWindowListFn = symbol("SLSHWCaptureWindowList", as: HWCaptureWindowListFn.self)
        ?? symbol("CGSHWCaptureWindowList", as: HWCaptureWindowListFn.self)
    private static let getWindowBoundsFn = symbol("SLSGetWindowBounds", as: GetWindowBoundsFn.self)
        ?? symbol("CGSGetWindowBounds", as: GetWindowBoundsFn.self)

    private static let authMessageClass: AnyClass? = {
        _ = skyLightHandle
        return NSClassFromString("SLSEventAuthenticationMessage")
    }()
    private static let authMessageSelector = NSSelectorFromString("messageWithEventRecord:pid:version:")
    private static let authMessageFactory: AuthMessageFactoryFn? = {
        guard let cls = authMessageClass,
              let method = class_getClassMethod(cls, authMessageSelector) else {
            return nil
        }
        return unsafeBitCast(method_getImplementation(method), to: AuthMessageFactoryFn.self)
    }()

    // MARK: - Availability

    static var canSetWindowLocation: Bool { setWindowLocationFn != nil }

    /// Focus-without-raise records need the record poster and a pid → PSN mapping,
    /// and undoing one needs the front-process check, so a record is never sent
    /// that could not be taken back.
    static var canPostFocusRecords: Bool {
        postEventRecordToFn != nil && getProcessForPIDFn != nil && getFrontProcessFn != nil
    }

    /// Authenticated SkyLight keyboard posting (Chromium/Electron on macOS 15+).
    static var canPostAuthenticatedEvents: Bool {
        slEventPostToPidFn != nil && slEventSetAuthenticationMessageFn != nil && authMessageFactory != nil
    }

    static var canGetAXWindow: Bool { axGetWindowFn != nil }

    static var canCaptureWindowList: Bool { mainConnectionIDFn != nil && hwCaptureWindowListFn != nil }

    static var canReadWindowFrames: Bool { mainConnectionIDFn != nil && getWindowBoundsFn != nil }

    static func symbolReport() -> [SymbolStatus] {
        [
            SymbolStatus(name: "CGEventSetWindowLocation", available: setWindowLocationFn != nil, usedBy: "window, focusAssisted (mouse)"),
            SymbolStatus(name: "SLEventPostToPid", available: slEventPostToPidFn != nil, usedBy: "focusAssisted (keyboard)"),
            SymbolStatus(name: "SLEventSetAuthenticationMessage", available: slEventSetAuthenticationMessageFn != nil, usedBy: "focusAssisted (keyboard)"),
            SymbolStatus(name: "SLSEventAuthenticationMessage", available: authMessageFactory != nil, usedBy: "focusAssisted (keyboard)"),
            SymbolStatus(name: "SLPSPostEventRecordTo", available: postEventRecordToFn != nil, usedBy: "focusAssisted"),
            SymbolStatus(name: "_SLPSGetFrontProcess", available: getFrontProcessFn != nil, usedBy: "focusAssisted, activation checks, frontmost app"),
            SymbolStatus(name: "GetProcessForPID", available: getProcessForPIDFn != nil, usedBy: "focusAssisted"),
            SymbolStatus(name: "GetProcessPID", available: getProcessPIDFn != nil, usedBy: "frontmost app"),
            SymbolStatus(name: "_AXUIElementGetWindow", available: axGetWindowFn != nil, usedBy: "elements --window-id"),
            SymbolStatus(name: "SLSHWCaptureWindowList", available: canCaptureWindowList, usedBy: "screenshot and state of windows not on screen"),
            SymbolStatus(name: "SLSGetWindowBounds", available: canReadWindowFrames, usedBy: "Stage Manager thumbnail detection"),
        ]
    }

    // MARK: - Calls

    /// Stamps a window-local location on a mouse event. Returns false when the
    /// symbol is missing; the caller decides whether that is fatal.
    @discardableResult
    static func setWindowLocation(_ event: CGEvent, _ location: CGPoint) -> Bool {
        guard let setWindowLocationFn else { return false }
        setWindowLocationFn(event, location)
        return true
    }

    /// Whether `pid` is the window server's front process right now. Nil when the
    /// symbols are missing or either lookup fails, so the caller can fall back.
    static func isFrontProcess(_ pid: pid_t) -> Bool? {
        guard let getFrontProcessFn, let getProcessForPIDFn else { return nil }
        var front = ProcessSerial()
        var target = ProcessSerial()
        guard getFrontProcessFn(&front) == 0, getProcessForPIDFn(pid, &target) == 0 else {
            return nil
        }
        return front == target
    }

    /// The pid of the window server's front process. Unlike `NSWorkspace`, this is
    /// current without a main run loop. Nil when a symbol is missing or a lookup fails.
    static func frontProcessPID() -> pid_t? {
        guard let getFrontProcessFn, let getProcessPIDFn else { return nil }
        var front = ProcessSerial()
        guard getFrontProcessFn(&front) == 0 else { return nil }
        var pid: pid_t = 0
        let status = withUnsafePointer(to: &front) { getProcessPIDFn(UnsafeRawPointer($0), &pid) }
        return status == 0 && pid > 0 ? pid : nil
    }

    /// Captures one window from the window server's own backing store, the call
    /// window switchers use for minimized windows. It also works for a hidden app's
    /// windows and for windows on another Space, which ScreenCaptureKit never
    /// returns an image for. The image is the full window frame at the backing
    /// scale, tagged with the display's color space. Nil when a symbol is missing
    /// or the window server returns nothing.
    static func captureWindowImage(_ windowID: CGWindowID) -> CGImage? {
        guard let mainConnectionIDFn, let hwCaptureWindowListFn else { return nil }
        // kCGSCaptureIgnoreGlobalClipShape | kCGSWindowCaptureBestResolution
        let options: UInt32 = (1 << 11) | (1 << 8)
        var id = windowID
        guard let list = hwCaptureWindowListFn(mainConnectionIDFn(), &id, 1, options)?.takeRetainedValue(),
              CFArrayGetCount(list) > 0,
              let first = CFArrayGetValueAtIndex(list, 0) else {
            return nil
        }
        let value = Unmanaged<AnyObject>.fromOpaque(first).takeUnretainedValue()
        guard CFGetTypeID(value) == CGImage.typeID else { return nil }
        let image = value as! CGImage
        return image.width > 0 && image.height > 0 ? image : nil
    }

    /// The window's own frame in global top-left points. `CGWindowListCopyWindowInfo`
    /// reports a window's on-screen bounds instead, which for a window shown as a
    /// Stage Manager thumbnail are the thumbnail's. Nil when a symbol is missing or
    /// the call fails.
    static func windowFrame(_ windowID: CGWindowID) -> CGRect? {
        guard let mainConnectionIDFn, let getWindowBoundsFn else { return nil }
        var frame = CGRect.zero
        guard getWindowBoundsFn(mainConnectionIDFn(), windowID, &frame) == 0,
              frame.width > 0, frame.height > 0 else {
            return nil
        }
        return frame
    }

    /// Maps an AX window element to its CGWindowID. Nil when the symbol is missing.
    static func axGetWindow(_ element: AXUIElement) -> (error: AXError, windowID: CGWindowID)? {
        guard let axGetWindowFn else { return nil }
        var windowID: CGWindowID = 0
        let error = axGetWindowFn(element, &windowID)
        return (error, windowID)
    }

    /// Posts through SkyLight with an `SLSEventAuthenticationMessage` attached, the
    /// path Chromium's synthetic-input filter accepts for background keyboard input.
    /// Returns false when any piece is unavailable, or when the event's record cannot
    /// be found and validated, so the caller can fall back to `CGEventPostToPid`.
    static func postAuthenticated(_ event: CGEvent, toPid pid: pid_t) -> Bool {
        guard let slEventPostToPidFn,
              let slEventSetAuthenticationMessageFn,
              let authMessageFactory,
              let cls = authMessageClass,
              let record = eventRecord(of: event) else {
            return false
        }

        return autoreleasepool {
            guard let message = authMessageFactory(cls, authMessageSelector, record, pid, 0)?.takeUnretainedValue() else {
                return false
            }
            slEventSetAuthenticationMessageFn(event, Unmanaged.passUnretained(message).toOpaque())
            slEventPostToPidFn(pid, event)
            return true
        }
    }

    /// The `SLSEventRecord *` a CGEvent wraps, or nil when no candidate checks out.
    ///
    /// CGEvent is opaque. On macOS 15 it is a 32-byte object with the record pointer
    /// at offset 24, and other releases have used 32 and 16. A candidate is used
    /// only when it passes `isEventRecord`, so a changed layout makes the caller fall
    /// back to plain per-pid posting instead of handing SkyLight a garbage pointer.
    static func eventRecord(of event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = UnsafeRawPointer(Unmanaged.passUnretained(event).toOpaque())
        // Never read past the CGEvent's own allocation.
        let objectSize = malloc_size(base)
        for offset in [24, 32, 16] where offset + MemoryLayout<UInt>.size <= objectSize {
            let candidate = base.load(fromByteOffset: offset, as: UInt.self)
            guard let pointer = UnsafeMutableRawPointer(bitPattern: candidate),
                  isEventRecord(pointer, type: event.type) else {
                continue
            }
            return pointer
        }
        return nil
    }

    /// The length an event record carries in its header, the 0xF8 bytes that the
    /// focus records below also use.
    static let eventRecordLength: UInt32 = 0xF8

    /// A pointer is taken for the event's record only when it is a live heap block
    /// at least one record long whose header holds the record length at byte 4 and
    /// the event's type at byte 8. `malloc_size` returns 0 for anything that is not
    /// the start of a heap block, so no unknown pointer is dereferenced.
    static func isEventRecord(_ pointer: UnsafeRawPointer, type: CGEventType) -> Bool {
        guard Int(bitPattern: pointer) % MemoryLayout<UInt>.alignment == 0,
              malloc_size(pointer) >= Int(eventRecordLength) else {
            return false
        }
        return pointer.load(fromByteOffset: 4, as: UInt32.self) == eventRecordLength
            && pointer.load(fromByteOffset: 8, as: UInt32.self) == type.rawValue
    }

    /// Focus without raise, addressed to the target alone: one 0xF8-byte WindowServer
    /// event record (the layout yabai and AltTab publish) that tells the target
    /// process its window gained focus (`focused: true`) or lost it (`false`).
    ///
    /// Records go only to `targetPid`. Nothing is posted to the real front process,
    /// so the user's app never hears that it lost key focus. It never calls
    /// `_SLPSSetFrontProcessWithOptions`, so the real frontmost app and window order
    /// are unchanged.
    ///
    /// Returns false when the symbols are missing or the record could not be posted.
    @discardableResult
    static func postFocusRecord(targetPid: pid_t, windowID: CGWindowID, focused: Bool) -> Bool {
        guard let postEventRecordToFn, let getProcessForPIDFn else {
            return false
        }
        var target = ProcessSerial()
        guard getProcessForPIDFn(targetPid, &target) == 0 else {
            return false
        }
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = 0x0D
        writeWindowID(windowID, into: &bytes)
        bytes[0x8A] = focused ? 0x01 : 0x02
        let status = withUnsafePointer(to: &target) { psn in
            postEventRecordToFn(UnsafeRawPointer(psn), bytes)
        }
        return status == 0
    }

    private static func writeWindowID(_ windowID: CGWindowID, into bytes: inout [UInt8]) {
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (index, byte) in raw.enumerated() {
                bytes[0x3C + index] = byte
            }
        }
    }
}
