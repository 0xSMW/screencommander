import ApplicationServices
import XCTest
@testable import ScreenCommander

final class AXTextInputWriteFailureTests: XCTestCase {
    private let element = AXElement.application(pid: 1)

    func testAppliedThrowingValueInsertDoesNotRefuse() throws {
        let actions = ThrowingTextActions()
        let result = try AXTextInput.write("X", replace: false, into: element, actions: actions, pause: {})
        XCTAssertEqual(result, .checked(true))
        XCTAssertEqual(actions.value, "aXb")
        XCTAssertEqual(actions.valueWrites, 1)
    }

    func testAppliedThrowingSelectedTextDoesNotTryValueWrite() throws {
        let actions = ThrowingTextActions()
        actions.selectedSettable = true
        let result = try AXTextInput.write("X", replace: false, into: element, actions: actions, pause: {})
        XCTAssertEqual(result, .checked(true))
        XCTAssertEqual(actions.value, "aXb")
        XCTAssertEqual(actions.valueWrites, 0)
        XCTAssertEqual(actions.selectedWrites, 1)
    }

    func testAppliedThrowingReplacementDoesNotRefuse() throws {
        let actions = ThrowingTextActions()
        let result = try AXTextInput.write("new", replace: true, into: element, actions: actions, pause: {})
        XCTAssertEqual(result, .checked(true))
        XCTAssertEqual(actions.value, "new")
    }

    func testRefusedThrowingWritesPermitFallbackAfterUnchangedReadback() {
        let actions = ThrowingTextActions()
        actions.selectedSettable = true
        actions.applies = false
        XCTAssertThrowsError(try AXTextInput.write("X", replace: false, into: element, actions: actions, pause: {})) {
            XCTAssertTrue($0 is AXTextInput.Refused)
        }
        XCTAssertEqual(actions.value, "ab")
        XCTAssertEqual(actions.selection, AXTextRange(location: 1, length: 0))
        XCTAssertEqual(actions.selectedWrites, 1)
        XCTAssertEqual(actions.valueWrites, 1)
        XCTAssertThrowsError(try AXTextInput.write("new", replace: true, into: element, actions: actions, pause: {})) {
            XCTAssertTrue($0 is AXTextInput.Refused)
        }
    }

    func testSecureThrowingSelectedTextRemainsUnverifiedWithoutReading() throws {
        let actions = ThrowingTextActions()
        actions.secure = true
        actions.selectedSettable = true
        XCTAssertEqual(try AXTextInput.write("X", replace: false, into: element, actions: actions, pause: {}), .unknown)
        XCTAssertEqual(actions.reads, 0)
        XCTAssertEqual(actions.valueWrites, 0)
    }

    func testUnreadableThrowingWritesRemainUnverified() throws {
        let actions = ThrowingTextActions()
        actions.readable = false
        actions.selectedSettable = true
        XCTAssertEqual(try AXTextInput.write("X", replace: false, into: element, actions: actions, pause: {}), .unknown)
        XCTAssertEqual(actions.valueWrites, 0)
        XCTAssertEqual(try AXTextInput.write("new", replace: true, into: element, actions: actions, pause: {}), .unknown)
    }

    func testSecureThrowingReplacementRemainsUnverifiedWithoutReading() throws {
        let actions = ThrowingTextActions()
        actions.secure = true
        XCTAssertEqual(try AXTextInput.write("new", replace: true, into: element, actions: actions, pause: {}), .unknown)
        XCTAssertEqual(actions.reads, 0)
    }
}

private final class ThrowingTextActions: AXActionPerforming {
    var value = "ab"
    var selection: AXTextRange? = AXTextRange(location: 1, length: 0)
    var selectedSettable = false
    var secure = false
    var readable = true
    var applies = true
    var reads = 0
    var valueWrites = 0
    var selectedWrites = 0

    func setValue(_ value: String, on element: AXElement) throws {
        valueWrites += 1
        if applies { self.value = value }
        throw ScreenCommanderError.elementNotActionable("cannotComplete")
    }
    func setSelectedText(_ text: String, on element: AXElement) throws {
        selectedWrites += 1
        if applies { value = AXTextInput.splice(text, into: value, at: selection) }
        throw ScreenCommanderError.elementNotActionable("cannotComplete")
    }
    func readValue(of element: AXElement) -> String? {
        reads += 1
        return readable ? value : nil
    }
    func isSettable(_ attribute: String, on element: AXElement) -> Bool {
        attribute == kAXValueAttribute || (attribute == kAXSelectedTextAttribute && selectedSettable)
    }
    func isSecureText(_ element: AXElement) -> Bool { secure }
    func readSelectedTextRange(of element: AXElement) -> AXTextRange? { selection }
    func setSelectedTextRange(_ range: AXTextRange, on element: AXElement) throws { selection = range }
    func readSelectedText(of element: AXElement) -> String? { nil }
    func perform(action: String, on element: AXElement) throws {}
    func attempt(action: String, on element: AXElement) -> AXError { .success }
    func raiseWindow(pid: pid_t, windowID: CGWindowID) throws {}
    func focus(on element: AXElement) throws {}
    func focusedTextElement(pid: pid_t, windowID: CGWindowID?) -> AXElement? { nil }
    func scrollByPage(_ element: AXElement, direction: ScrollDirection, pages: Int) throws -> AXScrollOutcome {
        AXScrollOutcome(method: "test", before: nil, after: nil)
    }
    func scrollPosition(of element: AXElement, direction: ScrollDirection) -> Double? { nil }
}
