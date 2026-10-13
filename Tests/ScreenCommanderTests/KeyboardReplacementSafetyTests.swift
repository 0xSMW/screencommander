import ApplicationServices
import CoreGraphics
import XCTest
@testable import ScreenCommander

private final class ReplacementActions: AXActionPerforming {
    var value: String? = "old😀"
    var secure = false
    var ignoreSelection = false
    var failSelection = false
    var selection: AXTextRange?
    var valueReads = 0
    func readValue(of element: AXElement) -> String? { valueReads += 1; return value }
    func isSecureText(_ element: AXElement) -> Bool { secure }
    func setSelectedTextRange(_ range: AXTextRange, on element: AXElement) throws {
        if failSelection { throw ScreenCommanderError.elementNotActionable("selection refused") }
        if !ignoreSelection { selection = range }
    }
    func readSelectedTextRange(of element: AXElement) -> AXTextRange? { selection }
    func perform(action: String, on element: AXElement) throws {}
    func attempt(action: String, on element: AXElement) -> AXError { .success }
    func raiseWindow(pid: pid_t, windowID: CGWindowID) throws {}
    func setValue(_ value: String, on element: AXElement) throws {}
    func focus(on element: AXElement) throws {}
    func readSelectedText(of element: AXElement) -> String? { nil }
    func setSelectedText(_ text: String, on element: AXElement) throws {}
    func isSettable(_ attribute: String, on element: AXElement) -> Bool { true }
    func focusedTextElement(pid: pid_t, windowID: CGWindowID?) -> AXElement? { nil }
    func scrollByPage(_ element: AXElement, direction: ScrollDirection, pages: Int) throws -> AXScrollOutcome {
        AXScrollOutcome(method: "unused", before: nil, after: nil)
    }
    func scrollPosition(of element: AXElement, direction: ScrollDirection) -> Double? { nil }
}

private final class ReplacementPoster: InputEventPosting {
    var events: [String] = []
    var onPrepare: () -> Void = {}
    func prepare(_ destination: InputEventDestination) throws { events.append("prepare"); onPrepare() }
    func post(_ event: CGEvent, to destination: InputEventDestination, kind: InputEventKind) { events.append("post") }
    func finish(_ destination: InputEventDestination) { events.append("finish") }
}

private final class ReplacementPasteboard: PasteboardAccess {
    var changeCount = 0
    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: []) }
    func replace(withString text: String) -> Int? { changeCount += 1; return changeCount }
    func restore(_ snapshot: PasteboardSnapshot) -> Bool { changeCount += 1; return true }
}

final class KeyboardReplacementSafetyTests: XCTestCase {
    private let element = AXElement.application(pid: 77)

    func testUnsafeSelectionsFailBeforeAnyKeyboardEvent() throws {
        for mode in [TextInputMode.unicode, .paste] {
            for failure in ["unreadable", "secure", "failed", "ignored", "unconfirmed"] {
                let actions = ReplacementActions()
                switch failure {
                case "unreadable": actions.value = nil
                case "secure": actions.secure = true
                case "failed": actions.failSelection = true
                case "ignored": actions.ignoreSelection = true; actions.selection = AXTextRange(location: 2, length: 0)
                default: actions.ignoreSelection = true
                }
                let poster = ReplacementPoster()
                let keyboard = KeyboardController(poster: poster, pasteboard: ReplacementPasteboard(), pasteboardRestoreDelayMicroseconds: 0)
                let callback = { try ScreenCommanderEngine.selectFullValueForKeyboardReplacement(self.element, actions: actions) }
                XCTAssertThrowsError(try deliver(mode, keyboard: keyboard, callback: callback), failure)
                XCTAssertEqual(poster.events, ["prepare", "finish"], failure)
                if failure == "secure" { XCTAssertEqual(actions.valueReads, 0) }
            }
        }
    }

    func testConfirmedSelectionHappensAfterPreparationAndStillTypes() throws {
        for mode in [TextInputMode.unicode, .paste] {
            let actions = ReplacementActions()
            let poster = ReplacementPoster()
            // Window preparation can move the caret. The proof must follow it.
            poster.onPrepare = { actions.selection = AXTextRange(location: 2, length: 0) }
            let keyboard = KeyboardController(poster: poster, pasteboard: ReplacementPasteboard(), pasteboardRestoreDelayMicroseconds: 0)
            try deliver(mode, keyboard: keyboard) {
                XCTAssertEqual(poster.events, ["prepare"])
                try ScreenCommanderEngine.selectFullValueForKeyboardReplacement(self.element, actions: actions)
                poster.events.append("confirmed")
            }
            XCTAssertEqual(actions.selection, AXTextRange(location: 0, length: 5))
            XCTAssertEqual(Array(poster.events.prefix(3)), ["prepare", "confirmed", "post"])
            XCTAssertEqual(poster.events.filter { $0 == "prepare" }.count, 1)
            XCTAssertEqual(poster.events.last, "finish")
        }
    }

    private func deliver(_ mode: TextInputMode, keyboard: KeyboardController, callback: () throws -> Void) throws {
        if mode == .paste {
            try keyboard.typeByPasting(text: "x", destination: .global, beforePosting: callback)
        } else {
            try keyboard.type(text: "x", delayMilliseconds: nil, destination: .global, beforePosting: callback)
        }
    }
}
