import CoreGraphics
import Darwin
import XCTest
@testable import ScreenCommander

/// A small model of running apps for keyboard tests that run the real
/// `KeyboardController` and `LiveInputEventPoster` end to end: which pid is the
/// real frontmost app, which apps were told they are active by a focus record, and
/// which window is key in each app. Every key event lands in the key window of its
/// pid at that moment, as AppKit does with events posted to a process.
final class SimulatedApps: FocusRecordPosting, KeyWindowReading {
    struct Record: Equatable {
        var pid: pid_t
        var windowID: CGWindowID
        var focused: Bool
    }

    var frontPid: pid_t? = 12
    var keyWindows: [pid_t: CGWindowID] = [:]
    /// False models a missing symbol (`_SLPSGetFrontProcess` alone, say).
    var focusRecordsAvailable = true
    var frontLookupFails = false
    /// False models a window that refuses to become key.
    var primerMakesKey = true
    var primerError: Error?
    /// Makes `pid` the real frontmost app when the primer runs, as an app that
    /// activates itself on a click would.
    var activatesOnPrime = false

    private(set) var active: Set<pid_t> = []
    private(set) var records: [Record] = []
    private(set) var primed: [CGWindowID] = []
    private(set) var keys: [(pid: pid_t, windowID: CGWindowID?, text: String)] = []

    var isAvailable: Bool { focusRecordsAvailable }

    func isFrontProcess(_ pid: pid_t) -> Bool? {
        frontLookupFails ? nil : frontPid == pid
    }

    func postFocusRecord(targetPid: pid_t, windowID: CGWindowID, focused: Bool) -> Bool {
        records.append(Record(pid: targetPid, windowID: windowID, focused: focused))
        if focused {
            active.insert(targetPid)
        } else {
            active.remove(targetPid)
        }
        return true
    }

    func keyWindowID(pid: pid_t) -> CGWindowID? {
        keyWindows[pid]
    }

    /// The key-window click: AppKit makes the window key on a mouse-down while the
    /// app believes it is active.
    func prime(_ target: InputWindowTarget, _ poster: InputEventPosting) throws {
        primed.append(target.windowID)
        if let primerError {
            throw primerError
        }
        if activatesOnPrime {
            frontPid = target.pid
        }
        if primerMakesKey, active.contains(target.pid) || frontPid == target.pid {
            keyWindows[target.pid] = target.windowID
        }
    }

    func deliver(_ event: CGEvent, _ destination: InputEventDestination, _ kind: InputEventKind) {
        guard kind == .keyboard, event.type == .keyDown, let pid = destination.targetPid else {
            return
        }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &characters)
        keys.append((pid, keyWindows[pid], String(utf16CodeUnits: characters, count: length)))
    }

    /// The text that reached one window.
    func text(in windowID: CGWindowID) -> String {
        keys.filter { $0.windowID == windowID }.map(\.text).joined()
    }

    func poster() -> LiveInputEventPoster {
        LiveInputEventPoster(
            focusRecords: self,
            keyWindows: self,
            primer: { [unowned self] target, poster in try self.prime(target, poster) },
            deliver: { [unowned self] event, destination, kind in self.deliver(event, destination, kind) },
            pause: { _ in }
        )
    }
}

final class LiveInputEventPosterTests: XCTestCase {
    private let first = InputWindowTarget(pid: 77, windowID: 500, bounds: CGRect(x: 100, y: 200, width: 400, height: 300))
    private let second = InputWindowTarget(pid: 77, windowID: 501, bounds: CGRect(x: 60, y: 210, width: 260, height: 200))

    private func makeApps() -> SimulatedApps {
        let apps = SimulatedApps()
        apps.keyWindows[77] = 500
        return apps
    }

    func testFocusAssistedPairsTheFocusRecordWithItsUndo() throws {
        let apps = makeApps()
        let keyboard = KeyboardController(poster: apps.poster())

        try keyboard.type(text: "ab", delayMilliseconds: nil, destination: .focusAssisted(first, authenticatedKeyboard: false))

        XCTAssertEqual(apps.records, [
            .init(pid: 77, windowID: 500, focused: true),
            .init(pid: 77, windowID: 500, focused: false),
        ])
        XCTAssertEqual(apps.text(in: 500), "ab")
        XCTAssertTrue(apps.active.isEmpty, "the target no longer believes it is active")
    }

    func testFinishUndoesTheFocusRecordWhenTheActionThrows() {
        let apps = makeApps()
        let keyboard = KeyboardController(poster: apps.poster())
        struct Boom: Error {}

        XCTAssertThrowsError(try keyboard.withPrepared(.focusAssisted(first, authenticatedKeyboard: false)) {
            throw Boom()
        })

        XCTAssertEqual(apps.records.map(\.focused), [true, false])
        XCTAssertTrue(apps.active.isEmpty)
    }

    func testFinishUndoesTheFocusRecordInACancelledTask() async throws {
        let apps = makeApps()
        let keyboard = KeyboardController(poster: apps.poster())
        let target = first

        let task = Task {
            // Cancelled before it starts: delivery is synchronous, so prepare and
            // finish still run as a pair.
            try keyboard.type(text: "c", delayMilliseconds: nil, destination: .focusAssisted(target, authenticatedKeyboard: false))
        }
        task.cancel()
        try await task.value

        XCTAssertEqual(apps.records.map(\.focused), [true, false])
        XCTAssertTrue(apps.active.isEmpty)
    }

    func testPrepareUndoesItsOwnFocusRecordWhenThePrimerFails() {
        let apps = makeApps()
        apps.primerError = ScreenCommanderError.backgroundDeliveryUnavailable("no window location")
        let keyboard = KeyboardController(poster: apps.poster())

        XCTAssertThrowsError(try keyboard.type(text: "x", delayMilliseconds: nil, destination: .focusAssisted(first, authenticatedKeyboard: false)))

        XCTAssertEqual(apps.records.map(\.focused), [true, false], "a failed prepare takes its focus record back")
        XCTAssertTrue(apps.keys.isEmpty)
    }

    func testNoFocusRecordIsSentWhenItCouldNotBeUndone() {
        for missing in ["symbols", "front lookup"] {
            let apps = makeApps()
            if missing == "symbols" {
                apps.focusRecordsAvailable = false
            } else {
                apps.frontLookupFails = true
            }
            let keyboard = KeyboardController(poster: apps.poster())

            XCTAssertThrowsError(
                try keyboard.type(text: "x", delayMilliseconds: nil, destination: .focusAssisted(first, authenticatedKeyboard: false)),
                missing
            ) { error in
                guard case ScreenCommanderError.backgroundDeliveryUnavailable = error else {
                    return XCTFail("\(missing): expected background_delivery_unavailable, got \(error)")
                }
            }
            XCTAssertTrue(apps.records.isEmpty, "\(missing): nothing to undo, so nothing was faked")
            XCTAssertTrue(apps.keys.isEmpty, missing)
        }
    }

    func testFinishLeavesATargetThatBecameFrontmostForReal() throws {
        let apps = makeApps()
        apps.activatesOnPrime = true
        let keyboard = KeyboardController(poster: apps.poster())

        try keyboard.type(text: "x", delayMilliseconds: nil, destination: .focusAssisted(first, authenticatedKeyboard: false))

        XCTAssertEqual(apps.records.map(\.focused), [true], "a real frontmost app keeps its real focus")
    }

    func testRequiredWindowIsMadeKeyBeforeKeysAreSent() throws {
        let apps = makeApps()
        let keyboard = KeyboardController(poster: apps.poster())

        try keyboard.type(text: "hi", delayMilliseconds: nil, destination: .focusAssisted(second.requiringKeyFocus(), authenticatedKeyboard: false))

        XCTAssertEqual(apps.text(in: 501), "hi")
        XCTAssertEqual(apps.text(in: 500), "")
    }

    func testRequiredWindowInTheFrontmostAppIsPrimedWithoutAFocusRecord() throws {
        let apps = makeApps()
        apps.frontPid = 77
        let keyboard = KeyboardController(poster: apps.poster())

        try keyboard.type(text: "hi", delayMilliseconds: nil, destination: .focusAssisted(second.requiringKeyFocus(), authenticatedKeyboard: false))

        XCTAssertTrue(apps.records.isEmpty, "the frontmost app has real focus")
        XCTAssertEqual(apps.primed, [501])
        XCTAssertEqual(apps.text(in: 501), "hi")
    }

    func testFrontmostAppWithoutARequiredWindowIsNotPrimed() throws {
        let apps = makeApps()
        apps.frontPid = 77
        let keyboard = KeyboardController(poster: apps.poster())

        try keyboard.type(text: "hi", delayMilliseconds: nil, destination: .focusAssisted(second, authenticatedKeyboard: false))

        XCTAssertTrue(apps.primed.isEmpty)
        XCTAssertEqual(apps.text(in: 500), "hi", "with no window named, keys go to the key window as before")
    }

    func testRequiredWindowThatStaysUnkeyedFailsWithNoKeysSent() {
        let apps = makeApps()
        apps.primerMakesKey = false
        let keyboard = KeyboardController(poster: apps.poster())

        XCTAssertThrowsError(
            try keyboard.type(text: "hi", delayMilliseconds: nil, destination: .focusAssisted(second.requiringKeyFocus(), authenticatedKeyboard: false))
        ) { error in
            guard case ScreenCommanderError.backgroundDeliveryUnavailable(let message) = error else {
                return XCTFail("expected background_delivery_unavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("window 500 is key"), message)
        }
        XCTAssertTrue(apps.keys.isEmpty)
        XCTAssertEqual(apps.records.map(\.focused), [true, false])
    }

    func testWindowTierRefusesARequiredWindowThatIsNotKey() throws {
        let apps = makeApps()
        let keyboard = KeyboardController(poster: apps.poster())

        XCTAssertThrowsError(try keyboard.type(text: "hi", delayMilliseconds: nil, destination: .window(second.requiringKeyFocus())))
        XCTAssertTrue(apps.keys.isEmpty, "keys would have landed in window 500")

        try keyboard.type(text: "ok", delayMilliseconds: nil, destination: .window(first.requiringKeyFocus()))
        XCTAssertEqual(apps.text(in: 500), "ok", "the key window itself takes plain window keys")
    }

    // MARK: - Key-window primer

    func testKeyWindowPrimerClicksOutsideTheWindowAddressedToIt() throws {
        try XCTSkipUnless(PrivateAPI.canSetWindowLocation, "CGEventSetWindowLocation is unavailable on this macOS.")
        let poster = RecordingInputPoster()

        try KeyWindowPrimer.prime(first, poster: poster)

        XCTAssertEqual(poster.eventTypes, [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(poster.prepared.isEmpty, "the primer runs inside an action's prepare")
        for posted in poster.posted {
            XCTAssertEqual(posted.destination, .window(first))
            XCTAssertEqual(posted.kind, .mouse)
            XCTAssertEqual(posted.event.location, CGPoint(x: 80, y: 180), "20 points above and left of the window")
            XCTAssertFalse(first.bounds.contains(posted.event.location))
            XCTAssertEqual(posted.event.getIntegerValueField(WindowEventStamper.windowNumberField), 500)
            XCTAssertEqual(posted.event.getIntegerValueField(WindowEventStamper.targetPidField), 77)
        }
    }

    func testKeyWindowPrimerGlobalPointIsOutsideTheFrame() {
        XCTAssertEqual(KeyWindowPrimer.globalPoint(for: second), CGPoint(x: 40, y: 190))
        XCTAssertFalse(second.bounds.contains(KeyWindowPrimer.globalPoint(for: second)))
    }

    // MARK: - Event records

    func testEventRecordOfAKeyEventPassesItsOwnCheck() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        guard let record = PrivateAPI.eventRecord(of: event) else {
            throw XCTSkip("This macOS keeps the event record somewhere the probe does not look; posting falls back to CGEventPostToPid.")
        }
        XCTAssertTrue(PrivateAPI.isEventRecord(record, type: .keyDown))
        XCTAssertFalse(PrivateAPI.isEventRecord(record, type: .leftMouseDown), "the type at byte 8 must match")
    }

    func testIsEventRecordAcceptsOnlyAHeapBlockWithTheRecordHeader() {
        let length = Int(PrivateAPI.eventRecordLength)
        let block = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { block.deallocate() }
        block.initializeMemory(as: UInt8.self, repeating: 0, count: length)
        block.storeBytes(of: PrivateAPI.eventRecordLength, toByteOffset: 4, as: UInt32.self)
        block.storeBytes(of: CGEventType.keyDown.rawValue, toByteOffset: 8, as: UInt32.self)

        XCTAssertTrue(PrivateAPI.isEventRecord(block, type: .keyDown))
        XCTAssertFalse(PrivateAPI.isEventRecord(block, type: .keyUp))
        XCTAssertFalse(PrivateAPI.isEventRecord(block + 8, type: .keyDown), "not the start of a heap block")

        block.storeBytes(of: UInt32(0x40), toByteOffset: 4, as: UInt32.self)
        XCTAssertFalse(PrivateAPI.isEventRecord(block, type: .keyDown), "wrong length in the header")

        let small = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        defer { small.deallocate() }
        small.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        small.storeBytes(of: PrivateAPI.eventRecordLength, toByteOffset: 4, as: UInt32.self)
        small.storeBytes(of: CGEventType.keyDown.rawValue, toByteOffset: 8, as: UInt32.self)
        XCTAssertFalse(PrivateAPI.isEventRecord(small, type: .keyDown), "a block shorter than a record")

        let stackValue: UInt64 = 0
        withUnsafeBytes(of: stackValue) { bytes in
            XCTAssertFalse(PrivateAPI.isEventRecord(bytes.baseAddress!, type: .keyDown), "not a heap block at all")
        }
    }
}

final class WindowHitTestTests: XCTestCase {
    private func info(
        _ number: Int, pid: Int, owner: String, layer: Int, _ rect: CGRect, alpha: Double = 1, title: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowBounds as String: rect.dictionaryRepresentation,
        ]
        if let title {
            entry[kCGWindowName as String] = title
        }
        return entry
    }

    private func hit(_ list: [[String: Any]], _ point: CGPoint, pid: pid_t? = nil) -> InputWindowTarget? {
        CGWindowLocator.topWindow(in: list, at: point, pid: pid, frame: { _ in nil })
    }

    func testHitTestReturnsTheTopmostWindowAtAnyLayer() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let list = [
            info(1, pid: 400, owner: "Window Server", layer: 24, CGRect(x: 0, y: 0, width: 1440, height: 24)),
            info(2, pid: 77, owner: "Fixture", layer: 101, CGRect(x: 300, y: 300, width: 120, height: 80)),
            info(3, pid: 500, owner: "Dock", layer: 20, CGRect(x: 400, y: 830, width: 600, height: 70)),
            info(4, pid: 77, owner: "Fixture", layer: 3, CGRect(x: 600, y: 100, width: 200, height: 100)),
            info(5, pid: 77, owner: "Fixture", layer: 0, CGRect(x: 100, y: 50, width: 900, height: 820)),
            info(6, pid: 600, owner: "Finder", layer: -2147483603, screen),
        ]

        XCTAssertEqual(hit(list, CGPoint(x: 350, y: 330))?.windowID, 2, "an open pop-up menu, not the document under it")
        XCTAssertEqual(hit(list, CGPoint(x: 350, y: 330))?.layer, 101)
        XCTAssertEqual(hit(list, CGPoint(x: 500, y: 850))?.ownerName, "Dock")
        XCTAssertEqual(hit(list, CGPoint(x: 10, y: 10))?.windowID, 1, "the menu bar")
        XCTAssertTrue(hit(list, CGPoint(x: 10, y: 10))?.isWindowServerOwned == true)
        XCTAssertEqual(hit(list, CGPoint(x: 650, y: 150))?.windowID, 4, "a floating panel")
        XCTAssertEqual(hit(list, CGPoint(x: 1200, y: 500))?.ownerName, "Finder", "the desktop")
        XCTAssertEqual(hit(list, CGPoint(x: 500, y: 850), pid: 77)?.windowID, 5, "limited to one app, the Dock does not count")
        XCTAssertEqual(hit(list, CGPoint(x: 350, y: 330), pid: 77)?.windowID, 2, "the app's own pop-up menu counts")
    }

    func testHitTestSkipsTheAgentCursorAndInvisibleWindows() {
        let list = [
            info(1, pid: 900, owner: "screencommander", layer: 0, CGRect(x: 0, y: 0, width: 40, height: 40)),
            info(2, pid: 901, owner: "Overlay", layer: 25, CGRect(x: 0, y: 0, width: 400, height: 400), alpha: 0),
            info(3, pid: 77, owner: "Fixture", layer: 0, CGRect(x: 0, y: 0, width: 400, height: 400)),
        ]

        XCTAssertEqual(hit(list, CGPoint(x: 10, y: 10))?.windowID, 3)
    }

    func testHitTestMatchesAStageManagerThumbnailAtItsThumbnailBounds() {
        let list = [info(7, pid: 77, owner: "Fixture", layer: 0, CGRect(x: 10, y: 200, width: 120, height: 90))]
        let frame = CGRect(x: 300, y: 100, width: 800, height: 600)

        let thumbnail = CGWindowLocator.topWindow(in: list, at: CGPoint(x: 50, y: 250), pid: nil, frame: { _ in frame })
        XCTAssertEqual(thumbnail?.isStageManagerThumbnail, true)
        XCTAssertNil(CGWindowLocator.topWindow(in: list, at: CGPoint(x: 600, y: 400), pid: nil, frame: { _ in frame }))
    }
}
