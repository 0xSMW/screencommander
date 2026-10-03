import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import ScreenCommander

/// Records what the controllers hand to the backend instead of posting it.
final class RecordingInputPoster: InputEventPosting {
    struct Posted {
        let event: CGEvent
        let destination: InputEventDestination
        let kind: InputEventKind
    }

    private(set) var prepared: [InputEventDestination] = []
    private(set) var posted: [Posted] = []
    private(set) var finished: [InputEventDestination] = []
    /// Events posted before each `finish`, to check it comes after the last event.
    private(set) var postedCountAtFinish: [Int] = []
    var prepareError: Error?

    func prepare(_ destination: InputEventDestination) throws {
        if let prepareError {
            throw prepareError
        }
        prepared.append(destination)
    }

    func post(_ event: CGEvent, to destination: InputEventDestination, kind: InputEventKind) {
        posted.append(Posted(event: event, destination: destination, kind: kind))
    }

    func finish(_ destination: InputEventDestination) {
        finished.append(destination)
        postedCountAtFinish.append(posted.count)
    }

    var eventTypes: [CGEventType] { posted.map(\.event.type) }
}

final class MouseControllerTests: XCTestCase {
    private let fixtureWindow = InputWindowTarget(
        pid: 4242,
        windowID: 777,
        bounds: CGRect(x: 100, y: 50, width: 400, height: 300)
    )

    func testHumanLikeSingleClickEmitsExactlyOneClick() throws {
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: false,
            tripleClick: false,
            primeClick: false,
            humanLike: true,
            modifiers: [],
            destination: .global
        )

        XCTAssertEqual(poster.eventTypes.filter { $0 == .leftMouseDown }.count, 1)
        XCTAssertEqual(poster.eventTypes.filter { $0 == .leftMouseUp }.count, 1)
    }

    func testHumanLikeDoubleClickEmitsExactlyTwoClicks() throws {
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: true,
            tripleClick: false,
            primeClick: false,
            humanLike: true,
            modifiers: [],
            destination: .global
        )

        let downs = poster.posted.filter { $0.event.type == .leftMouseDown }
        XCTAssertEqual(downs.count, 2)
        XCTAssertEqual(poster.eventTypes.filter { $0 == .leftMouseUp }.count, 2)
        XCTAssertEqual(downs.map { $0.event.getIntegerValueField(.mouseEventClickState) }, [1, 2])
    }

    func testRawSingleClickIsPrimerDownUp() throws {
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: false,
            tripleClick: false,
            primeClick: false,
            humanLike: false,
            modifiers: [],
            destination: .global
        )

        XCTAssertEqual(poster.eventTypes, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testPrimeAndHumanLikeShareOnePreClickMove() throws {
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: false,
            tripleClick: false,
            primeClick: true,
            humanLike: true,
            modifiers: [],
            destination: .global
        )

        let preClickMoves = poster.posted.filter {
            $0.event.type == .mouseMoved && $0.event.getIntegerValueField(.mouseEventClickState) == 0
        }
        XCTAssertEqual(preClickMoves.count, 1)
        XCTAssertEqual(poster.eventTypes.filter { $0 == .leftMouseDown }.count, 1)
        XCTAssertEqual(poster.eventTypes.filter { $0 == .leftMouseUp }.count, 1)
    }

    func testWindowClickStampsWindowPidAndButtonFields() throws {
        try XCTSkipUnless(PrivateAPI.canSetWindowLocation, "CGEventSetWindowLocation is unavailable on this macOS.")
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 150, y: 80),
            button: .right,
            doubleClick: false,
            tripleClick: false,
            primeClick: false,
            humanLike: false,
            modifiers: [],
            destination: .window(fixtureWindow)
        )

        XCTAssertEqual(poster.prepared, [.window(fixtureWindow)])
        XCTAssertEqual(poster.eventTypes, [.mouseMoved, .rightMouseDown, .rightMouseUp])
        for posted in poster.posted {
            let event = posted.event
            XCTAssertEqual(posted.destination, .window(fixtureWindow))
            XCTAssertEqual(posted.kind, .mouse)
            XCTAssertEqual(event.getIntegerValueField(WindowEventStamper.windowNumberField), 777)
            XCTAssertEqual(event.getIntegerValueField(WindowEventStamper.windowUnderPointerField), 777)
            XCTAssertEqual(event.getIntegerValueField(WindowEventStamper.windowThatCanHandleField), 777)
            XCTAssertEqual(event.getIntegerValueField(WindowEventStamper.targetPidField), 4242)
            XCTAssertEqual(event.getIntegerValueField(WindowEventStamper.mouseSubtypeField), WindowEventStamper.mouseSubtype)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), Int64(CGMouseButton.right.rawValue))
            XCTAssertEqual(event.location, CGPoint(x: 150, y: 80), "screen location stays global; the window-local copy is separate")
        }
        XCTAssertEqual(poster.posted[1].event.getIntegerValueField(.mouseEventClickState), 1)
    }

    func testMouseFlagsAreExactlyTheRequestedModifiers() throws {
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.click(
            at: CGPoint(x: 10, y: 20),
            button: .left,
            doubleClick: false,
            tripleClick: false,
            primeClick: false,
            humanLike: false,
            modifiers: ["cmd"],
            destination: .global
        )
        try controller.scroll(at: CGPoint(x: 10, y: 20), dx: 0, dy: -2, unit: .lines, destination: .global)

        let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        let clickFlags = poster.posted.prefix(3).map { $0.event.flags.intersection(modifierMask) }
        XCTAssertEqual(clickFlags, [.maskCommand, .maskCommand, .maskCommand])
        let scrollFlags = poster.posted.dropFirst(3).map { $0.event.flags.intersection(modifierMask) }
        XCTAssertEqual(scrollFlags, [[], []])
    }

    func testDragAndMoveUseTheGivenDestination() throws {
        try XCTSkipUnless(PrivateAPI.canSetWindowLocation, "CGEventSetWindowLocation is unavailable on this macOS.")
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)

        try controller.drag(
            from: CGPoint(x: 120, y: 60),
            to: CGPoint(x: 200, y: 100),
            button: .left,
            steps: 2,
            durationMS: 0,
            destination: .window(fixtureWindow)
        )
        try controller.move(to: CGPoint(x: 130, y: 70), destination: .window(fixtureWindow))

        XCTAssertEqual(
            poster.eventTypes,
            [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        )
        XCTAssertTrue(poster.posted.allSatisfy { $0.destination == .window(fixtureWindow) })
        XCTAssertTrue(poster.posted.allSatisfy {
            $0.event.getIntegerValueField(WindowEventStamper.targetPidField) == 4242
        })
    }

    func testFocusAssistedPreparesOncePerAction() throws {
        try XCTSkipUnless(PrivateAPI.canSetWindowLocation, "CGEventSetWindowLocation is unavailable on this macOS.")
        let poster = RecordingInputPoster()
        let controller = MouseController(poster: poster)
        let destination = InputEventDestination.focusAssisted(fixtureWindow, authenticatedKeyboard: false)

        try controller.click(
            at: CGPoint(x: 150, y: 80),
            button: .left,
            doubleClick: true,
            tripleClick: false,
            primeClick: false,
            humanLike: false,
            modifiers: [],
            destination: destination
        )

        XCTAssertEqual(poster.prepared, [destination], "focus records go out once, before the first event")
        XCTAssertEqual(poster.posted.count, 6)
        XCTAssertEqual(poster.finished, [destination], "the target hears it lost focus once, after the last event")
        XCTAssertEqual(poster.postedCountAtFinish, [6])
    }

    func testFailedPrepareSendsNoEvents() {
        let poster = RecordingInputPoster()
        poster.prepareError = ScreenCommanderError.backgroundDeliveryUnavailable("no records")
        let controller = MouseController(poster: poster)

        XCTAssertThrowsError(
            try controller.move(
                to: CGPoint(x: 1, y: 1),
                destination: .focusAssisted(fixtureWindow, authenticatedKeyboard: false)
            )
        )
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertTrue(poster.finished.isEmpty, "nothing to undo when the focus record never went out")
    }

    func testSyntheticEventSourceNeverSuppressesLocalInput() throws {
        let source = try XCTUnwrap(SyntheticEventSource.make())

        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
            let filter = source.getLocalEventsFilterDuringSuppressionState(state)
            XCTAssertTrue(filter.contains(.permitLocalKeyboardEvents))
            XCTAssertTrue(filter.contains(.permitLocalMouseEvents))
            XCTAssertTrue(filter.contains(.permitSystemDefinedEvents))
        }
    }

    func testScrollAcceptsNegativeDeltas() throws {
        let command = try ScrollCommand.parse(["640", "800", "--dy", "-5", "--dx", "-2"])
        XCTAssertEqual(command.dy, -5)
        XCTAssertEqual(command.dx, -2)
    }

    func testHitTestsNeverPickTheAgentCursor() {
        let cursorByTitle: [String: Any] = [
            kCGWindowName as String: "ScreenCommander Cursor",
            kCGWindowOwnerName as String: "screencommander",
        ]
        // Without Screen Recording the title is missing; the owner still identifies it.
        let cursorByOwner: [String: Any] = [kCGWindowOwnerName as String: "screencommander"]
        let app: [String: Any] = [kCGWindowName as String: "Document", kCGWindowOwnerName as String: "TextEdit"]

        XCTAssertTrue(CGWindowLocator.isAgentCursor(cursorByTitle))
        XCTAssertTrue(CGWindowLocator.isAgentCursor(cursorByOwner))
        XCTAssertFalse(CGWindowLocator.isAgentCursor(app))
    }

    func testRunningApplicationsNeverFallsBackToAStaleList() {
        XCTAssertTrue(RunningApplications.current(listPIDs: { nil }).isEmpty, "no kernel list means no apps, not NSWorkspace's cached list")
        XCTAssertTrue(RunningApplications.current(listPIDs: { [0, -1] }).isEmpty)
        XCTAssertNotNil(RunningApplications.kernelPIDs()?.first { $0 == getpid() }, "the live kernel list includes this process")
    }
}

final class KeyboardControllerTests: XCTestCase {
    private let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]

    func testChordGoesToPidWithExplicitCumulativeFlags() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        try controller.press(chord: try KeyCodes.parseChord("cmd+shift+t"), destination: .pid(31))

        XCTAssertEqual(poster.prepared, [.pid(31)])
        XCTAssertTrue(poster.posted.allSatisfy { $0.destination == .pid(31) && $0.kind == .keyboard })
        let codes = poster.posted.map { $0.event.getIntegerValueField(.keyboardEventKeycode) }
        XCTAssertEqual(codes, [
            Int64(kVK_Command), Int64(kVK_Shift), Int64(kVK_ANSI_T), Int64(kVK_ANSI_T), Int64(kVK_Shift), Int64(kVK_Command)
        ])
        let flags = poster.posted.map { $0.event.flags.intersection(modifierMask) }
        XCTAssertEqual(flags, [
            .maskCommand,
            [.maskCommand, .maskShift],
            [.maskCommand, .maskShift],
            [.maskCommand, .maskShift],
            .maskCommand,
            [],
        ])
    }

    func testUnicodeTypingHasNoModifierFlags() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        try controller.type(text: "hi", delayMilliseconds: nil, destination: .pid(31))

        XCTAssertEqual(poster.posted.count, 4)
        XCTAssertTrue(poster.posted.allSatisfy { $0.event.flags.intersection(modifierMask).isEmpty })
        XCTAssertTrue(poster.posted.allSatisfy { $0.destination == .pid(31) })
    }

    func testUnicodeTypingSendsEachCharacterWholeAndInOrder() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)
        let text = "Ça va? 👍🏽 中文 e\u{301}"

        try controller.type(text: text, delayMilliseconds: nil, destination: .pid(31))

        let downs = poster.posted.filter { $0.event.type == .keyDown }
        XCTAssertEqual(downs.count, text.count, "one key event per character, emoji and combining marks included")
        XCTAssertEqual(downs.map { Self.unicodeString(of: $0.event) }.joined(), text)
        XCTAssertTrue(downs.allSatisfy { $0.event.getIntegerValueField(.keyboardEventKeycode) == 0 })
    }

    func testLineBreaksAndTabsGoOutOnTheirOwnKeys() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        try controller.type(text: "a\nb\tc\r\nd", delayMilliseconds: nil, destination: .pid(31))

        let downs = poster.posted.filter { $0.event.type == .keyDown }
        XCTAssertEqual(downs.map { $0.event.getIntegerValueField(.keyboardEventKeycode) },
                       [0, Int64(kVK_Return), 0, Int64(kVK_Tab), 0, Int64(kVK_Return), 0])
        XCTAssertEqual(downs.map { Self.unicodeString(of: $0.event) }, ["a", "\r", "b", "\t", "c", "\r", "d"])
    }

    func testKeyEventInputNeverTouchesThePasteboard() throws {
        let poster = RecordingInputPoster()
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        let controller = KeyboardController(poster: poster, pasteboard: pasteboard, pasteboardRestoreDelayMicroseconds: 0)
        let window = InputWindowTarget(pid: 31, windowID: 9, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let destinations: [InputEventDestination] = [
            .global, .pid(31), .window(window), .focusAssisted(window, authenticatedKeyboard: true),
        ]

        for destination in destinations {
            try controller.type(text: "héllo 👍🏽\n", delayMilliseconds: nil, destination: destination)
            try controller.press(chord: try KeyCodes.parseChord("cmd+a"), destination: destination)
            try controller.run(sequence: try KeySequenceParser.parse(["down:shift", "press:a", "up:shift"]), destination: destination)
        }

        XCTAssertEqual(pasteboard.accessCount, 0, "only paste mode may read or write the pasteboard")
        try controller.typeByPasting(text: "x", destination: .global)
        XCTAssertGreaterThan(pasteboard.accessCount, 0)
    }

    private static func unicodeString(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    func testFocusAssistedKeyboardBracketsEventsWithTargetOnlyFocusChange() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)
        let target = InputWindowTarget(pid: 4242, windowID: 777, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let destination = InputEventDestination.focusAssisted(target, authenticatedKeyboard: false)

        try controller.type(text: "ab", delayMilliseconds: nil, destination: destination)
        try controller.press(chord: try KeyCodes.parseChord("cmd+a"), destination: destination)
        try controller.run(sequence: try KeySequenceParser.parse(["press:x"]), destination: destination)

        XCTAssertEqual(poster.prepared, [destination, destination, destination])
        XCTAssertEqual(poster.finished, [destination, destination, destination])
        XCTAssertEqual(poster.postedCountAtFinish, [4, 8, 10], "focus is handed back after each action's last event")
        XCTAssertTrue(poster.posted.allSatisfy { $0.destination.targetPid == 4242 }, "nothing goes to another process")
    }

    func testSequenceCarriesHeldModifiersOnLaterEvents() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        try controller.run(
            sequence: try KeySequenceParser.parse(["down:cmd", "press:tab", "up:cmd"]),
            destination: .pid(31)
        )

        let flags = poster.posted.map { $0.event.flags.intersection(modifierMask) }
        XCTAssertEqual(flags, [.maskCommand, .maskCommand, .maskCommand, []])
    }

    func testSystemKeyRefusesBackgroundDestination() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        XCTAssertThrowsError(try controller.press(chord: try KeyCodes.parseChord("volumeup"), destination: .pid(31))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertThrowsError(
            try controller.run(sequence: try KeySequenceParser.parse(["press:a", "press:volumeup"]), destination: .pid(31))
        )
        XCTAssertTrue(poster.posted.isEmpty, "a sequence with a system key must not deliver partially")
    }

    func testSystemShortcutAliasRefusesBackgroundDestination() throws {
        let poster = RecordingInputPoster()
        let controller = KeyboardController(poster: poster)

        XCTAssertThrowsError(try controller.press(chord: try KeyCodes.parseChord("spotlight"), destination: .pid(31))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertThrowsError(
            try controller.run(sequence: try KeySequenceParser.parse(["press:a", "press:missioncontrol"]), destination: .pid(31))
        )
        XCTAssertTrue(poster.posted.isEmpty, "nothing is delivered for a refused alias")

        try controller.press(chord: try KeyCodes.parseChord("cmd+space"), destination: .pid(31))
        XCTAssertFalse(poster.posted.isEmpty, "a raw chord is still delivered to the target")
    }

    // MARK: - Paste mode pasteboard

    private static let imageClipboard = PasteboardSnapshot(items: [
        [
            PasteboardSnapshot.Value(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            PasteboardSnapshot.Value(type: "public.tiff", data: Data([0x4D, 0x4D])),
        ],
        [PasteboardSnapshot.Value(type: "public.utf8-plain-text", data: Data("caption".utf8))],
    ])

    func testPasteRestoresEveryItemAndTypeAfterTheTargetReadsIt() throws {
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        var seenDuringWait: String?
        var bodyRan = false

        try PasteboardSwap.withTemporaryString("hello", on: pasteboard, wait: {
            seenDuringWait = pasteboard.text
        }) {
            XCTAssertEqual(pasteboard.text, "hello")
            bodyRan = true
        }

        XCTAssertTrue(bodyRan)
        XCTAssertEqual(seenDuringWait, "hello", "the text stays on the pasteboard until the wait is over")
        XCTAssertEqual(pasteboard.contents, Self.imageClipboard)
    }

    func testPasteRestoresImmediatelyWhenDeliveryFails() {
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        var waited = false

        XCTAssertThrowsError(try PasteboardSwap.withTemporaryString("hello", on: pasteboard, wait: { waited = true }) {
            throw ScreenCommanderError.backgroundDeliveryUnavailable("no focus record")
        }) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertFalse(waited)
        XCTAssertEqual(pasteboard.contents, Self.imageClipboard)
    }

    func testPasteRestoresWhenTheWriteFailsAfterClearing() {
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        pasteboard.failWrites = true
        var bodyRan = false

        XCTAssertThrowsError(try PasteboardSwap.withTemporaryString("hello", on: pasteboard, wait: {}) { bodyRan = true })
        XCTAssertFalse(bodyRan)
        XCTAssertEqual(pasteboard.contents, Self.imageClipboard)
    }

    func testPasteLeavesNewerClipboardContentAlone() throws {
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        let userCopy = PasteboardSnapshot(items: [[PasteboardSnapshot.Value(type: "public.utf8-plain-text", data: Data("mine".utf8))]])

        try PasteboardSwap.withTemporaryString("hello", on: pasteboard, wait: {
            pasteboard.externalWrite(userCopy)
        }) {}
        XCTAssertEqual(pasteboard.contents, userCopy)

        XCTAssertThrowsError(try PasteboardSwap.withTemporaryString("hello", on: pasteboard, wait: {}) {
            pasteboard.externalWrite(Self.imageClipboard)
            throw ScreenCommanderError.inputSynthesisFailed("late failure")
        })
        XCTAssertEqual(pasteboard.contents, Self.imageClipboard, "the newer write wins over the saved snapshot")
    }

    func testTypeByPastingPostsCommandVAndRestoresClipboard() throws {
        let poster = RecordingInputPoster()
        let pasteboard = FakePasteboard(contents: Self.imageClipboard)
        let controller = KeyboardController(poster: poster, pasteboard: pasteboard, pasteboardRestoreDelayMicroseconds: 0)

        try controller.typeByPasting(text: "hello", destination: .pid(31))

        let keyDowns = poster.posted.filter { $0.event.type == .keyDown }
        XCTAssertEqual(keyDowns.map { $0.event.getIntegerValueField(.keyboardEventKeycode) }, [Int64(kVK_ANSI_V)])
        XCTAssertEqual(keyDowns.first?.event.flags.intersection(modifierMask), .maskCommand)
        XCTAssertEqual(pasteboard.contents, Self.imageClipboard)
        XCTAssertEqual(pasteboard.textHistory, ["hello"])
    }
}

private final class FakePasteboard: PasteboardAccess {
    private(set) var contents: PasteboardSnapshot
    private var count = 1
    private(set) var textHistory: [String] = []
    /// Every read or write through `PasteboardAccess`.
    private(set) var accessCount = 0
    var failWrites = false

    init(contents: PasteboardSnapshot) {
        self.contents = contents
    }

    var changeCount: Int {
        accessCount += 1
        return count
    }

    var text: String? {
        contents.items.first?.first { $0.type == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    func snapshot() -> PasteboardSnapshot {
        accessCount += 1
        return contents
    }

    func replace(withString text: String) -> Int? {
        accessCount += 1
        contents = PasteboardSnapshot(items: [])
        count += 1
        guard !failWrites else { return nil }
        contents = PasteboardSnapshot(items: [[PasteboardSnapshot.Value(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        textHistory.append(text)
        return count
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        accessCount += 1
        count += 1
        contents = snapshot
        return true
    }

    func externalWrite(_ snapshot: PasteboardSnapshot) {
        count += 1
        contents = snapshot
    }
}
