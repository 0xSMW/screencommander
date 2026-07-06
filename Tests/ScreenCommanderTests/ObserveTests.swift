import ApplicationServices
import Foundation
import XCTest
@testable import ScreenCommander

final class ObserveTests: XCTestCase {
    // MARK: - Helpers

    private func assertInvalidArguments<T>(
        _ body: @autoclosure () throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            guard let scError = error as? ScreenCommanderError,
                  scError.stableCode == "invalid_arguments" else {
                XCTFail("Expected invalid_arguments, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func decode(_ line: String) throws -> [String: Any] {
        let data = try XCTUnwrap(line.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Predicate parsing

    func testPredicateParsesEqualsCondition() throws {
        let predicate = try ObservePredicate.parse("role=AXButton")
        XCTAssertEqual(predicate.conditions.count, 1)
        XCTAssertEqual(predicate.conditions[0].key, .role)
        XCTAssertEqual(predicate.conditions[0].op, .equals)
        XCTAssertEqual(predicate.conditions[0].expected, "AXButton")
    }

    func testPredicateParsesContainsCondition() throws {
        let predicate = try ObservePredicate.parse("title~=Save")
        XCTAssertEqual(predicate.conditions.count, 1)
        XCTAssertEqual(predicate.conditions[0].key, .title)
        XCTAssertEqual(predicate.conditions[0].op, .contains)
        XCTAssertEqual(predicate.conditions[0].expected, "Save")
    }

    func testPredicateParsesConjunction() throws {
        let predicate = try ObservePredicate.parse("role=AXButton   title~=Save")
        XCTAssertEqual(predicate.conditions.count, 2)
        XCTAssertEqual(predicate.conditions[0].key, .role)
        XCTAssertEqual(predicate.conditions[1].key, .title)
        XCTAssertEqual(predicate.conditions[1].op, .contains)
    }

    func testPredicateParsesAllKeys() throws {
        let predicate = try ObservePredicate.parse("role=a title=b value=c id=0.1")
        XCTAssertEqual(predicate.conditions.map(\.key), [.role, .title, .value, .id])
    }

    func testPredicateRejectsMissingOperator() {
        assertInvalidArguments(try ObservePredicate.parse("role"))
    }

    func testPredicateRejectsUnknownKey() {
        assertInvalidArguments(try ObservePredicate.parse("name=Safari"))
    }

    func testPredicateRejectsEmptyKey() {
        assertInvalidArguments(try ObservePredicate.parse("=AXButton"))
    }

    func testPredicateRejectsEmptyValue() {
        assertInvalidArguments(try ObservePredicate.parse("role="))
        assertInvalidArguments(try ObservePredicate.parse("title~="))
    }

    func testPredicateRejectsEmptyString() {
        assertInvalidArguments(try ObservePredicate.parse("   "))
    }

    // MARK: - Predicate matching

    func testPredicateEqualsIsExactAndCaseSensitive() throws {
        let predicate = try ObservePredicate.parse("role=AXButton")
        XCTAssertTrue(predicate.matches(AXElementRecord(id: "0", role: "AXButton")))
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "axbutton")))
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "AXButtonBar")))
    }

    func testPredicateContainsIsCaseInsensitiveSubstring() throws {
        let predicate = try ObservePredicate.parse("title~=save")
        XCTAssertTrue(predicate.matches(AXElementRecord(id: "0", role: "AXButton", title: "Save File")))
        XCTAssertTrue(predicate.matches(AXElementRecord(id: "0", role: "AXButton", title: "AUTOSAVE")))
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "AXButton", title: "Open")))
        // Missing title is treated as empty and never contains a nonempty needle.
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "AXButton")))
    }

    func testPredicateConjunctionRequiresAllConditions() throws {
        let predicate = try ObservePredicate.parse("role=AXButton title~=Save")
        XCTAssertTrue(predicate.matches(AXElementRecord(id: "0", role: "AXButton", title: "Save Document")))
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "AXButton", title: "Open")))
        XCTAssertFalse(predicate.matches(AXElementRecord(id: "0", role: "AXMenuItem", title: "Save Document")))
    }

    func testPredicateMatchesOnValueAndId() throws {
        let byValue = try ObservePredicate.parse("value~=hello")
        XCTAssertTrue(byValue.matches(AXElementRecord(id: "0", role: "AXTextField", value: "hello world")))
        let byID = try ObservePredicate.parse("id=0.3.2")
        XCTAssertTrue(byID.matches(AXElementRecord(id: "0.3.2", role: "AXButton")))
        XCTAssertFalse(byID.matches(AXElementRecord(id: "0.3", role: "AXButton")))
    }

    func testFirstMatchReturnsFirstMatchingRecord() throws {
        let predicate = try ObservePredicate.parse("role=AXButton")
        let records = [
            AXElementRecord(id: "0", role: "AXWindow"),
            AXElementRecord(id: "0.0", role: "AXButton", title: "First"),
            AXElementRecord(id: "0.1", role: "AXButton", title: "Second")
        ]
        XCTAssertEqual(predicate.firstMatch(in: records)?.title, "First")
        let noMatch = try ObservePredicate.parse("role=AXSlider")
        XCTAssertNil(noMatch.firstMatch(in: records))
    }

    // MARK: - Event-kind list parsing

    func testEventKindParseListDefaultsToAll() throws {
        XCTAssertEqual(try ObservedEventKind.parseList(nil), Set(ObservedEventKind.allCases))
        XCTAssertEqual(try ObservedEventKind.parseList("   "), Set(ObservedEventKind.allCases))
    }

    func testEventKindParseListSelectsSubset() throws {
        XCTAssertEqual(try ObservedEventKind.parseList("value,focus"), [.value, .focus])
        XCTAssertEqual(try ObservedEventKind.parseList(" value , focus "), [.value, .focus])
        XCTAssertEqual(try ObservedEventKind.parseList("APP"), [.app])
    }

    func testEventKindParseListRejectsUnknown() {
        assertInvalidArguments(try ObservedEventKind.parseList("value,bogus"))
    }

    // MARK: - Notification mapping

    func testNotificationNamesForKinds() {
        let names = ObservedNotification.axNotificationNames(for: [.value])
        XCTAssertEqual(names, [kAXValueChangedNotification as String])

        let windowNames = ObservedNotification.axNotificationNames(for: [.window])
        XCTAssertTrue(windowNames.contains(kAXWindowMovedNotification as String))
        XCTAssertTrue(windowNames.contains(kAXTitleChangedNotification as String))

        // `.app` has no AX notifications (it is NSWorkspace-backed).
        XCTAssertTrue(ObservedNotification.axNotificationNames(for: [.app]).isEmpty)
    }

    func testNotificationClassify() {
        XCTAssertEqual(ObservedNotification.classify(axNotification: kAXValueChangedNotification as String)?.event, "value_changed")
        XCTAssertEqual(ObservedNotification.classify(axNotification: kAXValueChangedNotification as String)?.kind, .value)
        XCTAssertEqual(ObservedNotification.classify(axNotification: kAXWindowMovedNotification as String)?.event, "window_moved")
        XCTAssertEqual(ObservedNotification.classify(axNotification: kAXWindowMovedNotification as String)?.kind, .window)
        XCTAssertEqual(ObservedNotification.classify(axNotification: kAXUIElementDestroyedNotification as String)?.event, "element_destroyed")
        XCTAssertNil(ObservedNotification.classify(axNotification: "AXNotARealNotification"))
    }

    // MARK: - Event serialization

    func testObservedEventNDJSONLine() throws {
        let event = ObservedEvent(
            ts: "2026-07-06T12:00:00.000Z",
            kind: .value,
            event: "value_changed",
            app: ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil),
            element: AXElementRecord(id: "0.1", role: "AXTextField", value: "hi")
        )
        let line = try event.ndjsonLine()

        XCTAssertFalse(line.contains("\n"), "NDJSON line must be single-line")
        let object = try decode(line)
        XCTAssertEqual(object["ts"] as? String, "2026-07-06T12:00:00.000Z")
        XCTAssertEqual(object["event"] as? String, "value_changed")
        XCTAssertNil(object["kind"], "kind is internal and must not be serialized")

        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(app["pid"] as? Int, 42)
        XCTAssertEqual(app["name"] as? String, "TextEdit")

        let element = try XCTUnwrap(object["element"] as? [String: Any])
        XCTAssertEqual(element["role"] as? String, "AXTextField")
        XCTAssertEqual(element["value"] as? String, "hi")
    }

    func testObservedEventOmitsElementWhenNil() throws {
        let event = ObservedEvent(
            ts: "2026-07-06T12:00:00.000Z",
            kind: .app,
            event: "app_activated",
            app: ResolvedApp(pid: 7, name: "Finder", bundleID: nil),
            element: nil
        )
        let object = try decode(try event.ndjsonLine())
        XCTAssertNil(object["element"])
        XCTAssertEqual(object["event"] as? String, "app_activated")
    }

    func testObserveMatchNDJSONLine() throws {
        let match = ObserveMatch(element: AXElementRecord(id: "0.2", role: "AXWindow", title: "Downloads"))
        let object = try decode(try match.ndjsonLine())
        XCTAssertEqual(object["matched"] as? Bool, true)
        let element = try XCTUnwrap(object["element"] as? [String: Any])
        XCTAssertEqual(element["title"] as? String, "Downloads")
    }

    func testObserveMatchOmitsElementWhenNil() throws {
        let object = try decode(try ObserveMatch(element: nil).ndjsonLine())
        XCTAssertEqual(object["matched"] as? Bool, true)
        XCTAssertNil(object["element"])
    }

    // MARK: - Exit code

    func testObserveTimeoutExitCode() {
        XCTAssertEqual(ScreenCommanderError.observeTimeout("x").exitCode, 73)
        XCTAssertEqual(ScreenCommanderError.observeTimeout("x").stableCode, "observe_timeout")
    }
}
