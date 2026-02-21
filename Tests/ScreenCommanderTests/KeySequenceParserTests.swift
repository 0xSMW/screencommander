import XCTest
import Carbon.HIToolbox
@testable import ScreenCommander

final class KeySequenceParserTests: XCTestCase {
    func testParsesSimpleHoldSequence() throws {
        let sequence = try KeySequenceParser.parse([
            "down:cmd",
            "press:tab",
            "press:tab",
            "up:cmd"
        ])

        XCTAssertEqual(sequence.steps.count, 4)

        guard case .keyDown(let downKey, _) = sequence.steps[0] else {
            return XCTFail("Expected first step to be keyDown")
        }

        if case .keyboard(let downCode, _) = downKey {
            XCTAssertEqual(downCode, CGKeyCode(kVK_Command))
        } else {
            XCTFail("Expected keyboard key on keyDown")
        }

        guard case .press(let pressKey, _) = sequence.steps[1] else {
            return XCTFail("Expected second step to be press")
        }
        if case .keyboard(let pressCode, _) = pressKey {
            XCTAssertEqual(pressCode, CGKeyCode(kVK_Tab))
        } else {
            XCTFail("Expected keyboard key on press")
        }

        guard case .keyUp(let upKey, _) = sequence.steps[3] else {
            return XCTFail("Expected fourth step to be keyUp")
        }
        if case .keyboard(let upCode, _) = upKey {
            XCTAssertEqual(upCode, CGKeyCode(kVK_Command))
        } else {
            XCTFail("Expected keyboard key on keyUp")
        }
    }

    func testParsesPressWithModifierAndSystemSteps() throws {
        let sequence = try KeySequenceParser.parse([
            "press:ctrl+tab",
            "down:cmd",
            "press:next",
            "up:cmd"
        ])

        guard case .press(let pressKey, let pressFlags) = sequence.steps[0] else {
            return XCTFail("Expected first step to be press")
        }
        if case .keyboard(let pressCode, _) = pressKey {
            XCTAssertEqual(pressCode, CGKeyCode(kVK_Tab))
            XCTAssertEqual(pressFlags, .maskControl)
        } else {
            XCTFail("Expected keyboard key for press")
        }

        guard case .keyDown(let downKey, _) = sequence.steps[1] else {
            return XCTFail("Expected second step to be keyDown")
        }
        if case .keyboard(let downCode, _) = downKey {
            XCTAssertEqual(downCode, CGKeyCode(kVK_Command))
        } else {
            XCTFail("Expected keyboard key for keyDown")
        }

        guard case .press(let systemKey, _) = sequence.steps[2] else {
            return XCTFail("Expected third step to be press")
        }
        if case .system(let resolvedSystemKey, _) = systemKey {
            XCTAssertEqual(resolvedSystemKey, .nextTrack)
        } else {
            XCTFail("Expected system key for third step")
        }

        guard case .keyUp(let upKey, _) = sequence.steps[3] else {
            return XCTFail("Expected fourth step to be keyUp")
        }
        if case .keyboard(let upCode, _) = upKey {
            XCTAssertEqual(upCode, CGKeyCode(kVK_Command))
        } else {
            XCTFail("Expected keyboard key on keyUp")
        }
    }

    func testParsesSleepStep() throws {
        let sequence = try KeySequenceParser.parse(["sleep:120"])

        guard case .sleep(let milliseconds) = sequence.steps[0] else {
            return XCTFail("Expected sleep step")
        }
        XCTAssertEqual(milliseconds, 120)
    }

    func testRejectsEmptySequence() {
        XCTAssertThrowsError(try KeySequenceParser.parse([]))
    }

    func testRejectsInvalidAction() {
        XCTAssertThrowsError(try KeySequenceParser.parse(["foo:cmd"]))
    }

    func testRejectsNegativeSleep() {
        XCTAssertThrowsError(try KeySequenceParser.parse(["sleep:-5"]))
    }

    func testRejectsBadDownUpPayload() {
        XCTAssertThrowsError(try KeySequenceParser.parse(["down:cmd+tab"]))
        XCTAssertThrowsError(try KeySequenceParser.parse(["up:fn"]))
    }

    func testRejectsBlankStep() {
        XCTAssertThrowsError(try KeySequenceParser.parse([" "]))
    }

    func testParsesSystemKeyPressStep() throws {
        let sequence = try KeySequenceParser.parse(["press:next"])

        guard case .press(let key, _) = sequence.steps[0] else {
            return XCTFail("Expected press step")
        }
        if case .system(let systemKey, _) = key {
            XCTAssertEqual(systemKey, .nextTrack)
        } else {
            XCTFail("Expected system key")
        }
    }

    func testParsesSpecialMacroPressSteps() throws {
        let sequence = try KeySequenceParser.parse(["press:spotlight", "press:raycast", "press:missioncontrol"])

        guard case .press(let spotlight, _) = sequence.steps[0] else {
            return XCTFail("Expected first step to be spotlight press")
        }
        if case .keyboard(let spotlightCode, _) = spotlight {
            XCTAssertEqual(spotlightCode, CGKeyCode(kVK_Space))
        } else {
            XCTFail("Expected keyboard key for spotlight")
        }

        guard case .press(let raycast, _) = sequence.steps[1] else {
            return XCTFail("Expected second step to be raycast press")
        }
        if case .keyboard(let raycastCode, _) = raycast {
            XCTAssertEqual(raycastCode, CGKeyCode(kVK_Space))
        } else {
            XCTFail("Expected keyboard key for raycast")
        }

        guard case .press(let missionControl, let missionControlFlags) = sequence.steps[2] else {
            return XCTFail("Expected third step to be missioncontrol press")
        }
        XCTAssertEqual(missionControlFlags, .init())
        if case .keyboard(let missionCode, _) = missionControl {
            XCTAssertEqual(missionCode, CGKeyCode(kVK_F3))
        } else {
            XCTFail("Expected keyboard key for missioncontrol")
        }
    }
}
