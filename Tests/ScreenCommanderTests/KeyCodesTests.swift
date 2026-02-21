import XCTest
import Carbon.HIToolbox
@testable import ScreenCommander

final class KeyCodesTests: XCTestCase {
    func testParsesBasicKeyboardChord() throws {
        let chord = try KeyCodes.parseChord("cmd+shift+4")

        XCTAssertEqual(chord.key.keyboardCode, CGKeyCode(kVK_ANSI_4))
        XCTAssertEqual(chord.normalized, "cmd+shift+4")
    }

    func testParsesAliasAndFunctionKeys() throws {
        let chord = try KeyCodes.parseChord("fn+f5")

        if case .keyboard(let keyCode, _) = chord.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_F5))
        } else {
            XCTFail("Expected keyboard key for fn+f5.")
        }

        XCTAssertEqual(chord.normalized, "fn+f5")

        let command = try KeyCodes.parseChord("control+f19")
        if case .keyboard(let keyCode, _) = command.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_F19))
        } else {
            XCTFail("Expected keyboard key for control+f19.")
        }

        XCTAssertEqual(command.normalized, "ctrl+f19")
    }

    func testParsesModifierAliasesAndNormalizationOrder() throws {
        let chord = try KeyCodes.parseChord("Shift+CMD+PgUp")
        XCTAssertEqual(chord.normalized, "cmd+shift+pgup")

        let duplicate = try KeyCodes.parseChord("ctrl+control+cmd+command+fn+shift+f1")
        XCTAssertEqual(duplicate.normalized, "cmd+shift+ctrl+fn+f1")
    }

    func testParsesNavigationAndKeypad() throws {
        let chord = try KeyCodes.parseChord("pageup")
        if case .keyboard(let keyCode, _) = chord.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_PageUp))
        } else {
            XCTFail("Expected keyboard key for pageup.")
        }

        let keypad = try KeyCodes.parseChord("keypad+")
        if case .keyboard(let keyCode, _) = keypad.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_ANSI_KeypadPlus))
        } else {
            XCTFail("Expected keyboard key for keypad+")
        }

        let keypadDivide = try KeyCodes.parseChord("keypad/")
        if case .keyboard(let keypadSlashCode, _) = keypadDivide.key {
            XCTAssertEqual(keypadSlashCode, CGKeyCode(kVK_ANSI_KeypadDivide))
        } else {
            XCTFail("Expected keyboard key for keypad/")
        }

        let keypadDot = try KeyCodes.parseChord(" keypad. ")
        if case .keyboard(let keypadDotCode, _) = keypadDot.key {
            XCTAssertEqual(keypadDotCode, CGKeyCode(kVK_ANSI_KeypadDecimal))
        } else {
            XCTFail("Expected keyboard key for keypad.")
        }
    }

    func testParsesCompleteFunctionRow() throws {
        let functionMap: [(String, CGKeyCode)] = [
            ("f1", CGKeyCode(kVK_F1)),
            ("f2", CGKeyCode(kVK_F2)),
            ("f3", CGKeyCode(kVK_F3)),
            ("f4", CGKeyCode(kVK_F4)),
            ("f5", CGKeyCode(kVK_F5)),
            ("f6", CGKeyCode(kVK_F6)),
            ("f7", CGKeyCode(kVK_F7)),
            ("f8", CGKeyCode(kVK_F8)),
            ("f9", CGKeyCode(kVK_F9)),
            ("f10", CGKeyCode(kVK_F10)),
            ("f11", CGKeyCode(kVK_F11)),
            ("f12", CGKeyCode(kVK_F12)),
            ("f13", CGKeyCode(kVK_F13)),
            ("f14", CGKeyCode(kVK_F14)),
            ("f15", CGKeyCode(kVK_F15)),
            ("f16", CGKeyCode(kVK_F16)),
            ("f17", CGKeyCode(kVK_F17)),
            ("f18", CGKeyCode(kVK_F18)),
            ("f19", CGKeyCode(kVK_F19)),
            ("f20", CGKeyCode(kVK_F20))
        ]

        for (token, expectedCode) in functionMap {
            let chord = try KeyCodes.parseChord(token)
            if case .keyboard(let keyCode, _) = chord.key {
                XCTAssertEqual(keyCode, expectedCode, "Expected \(token) => \(expectedCode)")
            } else {
                XCTFail("Expected keyboard key for \(token).")
            }
        }
    }

    func testParsesSystemMediaKey() throws {
        let chord = try KeyCodes.parseChord("volumeup")

        if case .system(let key, _) = chord.key {
            XCTAssertEqual(key, .volumeUp)
        } else {
            XCTFail("Expected system key for volumeup.")
        }
    }

    func testParsesSystemKeyAliases() throws {
        let chord = try KeyCodes.parseChord("next_track")
        if case .system(let key, _) = chord.key {
            XCTAssertEqual(key, .nextTrack)
            XCTAssertEqual(chord.normalized, "nexttrack")
        } else {
            XCTFail("Expected system key for next_track.")
        }

        let aliases = ["voldown", "brightness_up", "prev", "launchpad"]
        let expectedSystems: [SystemKey] = [.volumeDown, .brightnessUp, .previousTrack, .launchpad]

        for (token, expected) in zip(aliases, expectedSystems) {
            let aliasChord = try KeyCodes.parseChord(token)
            if case .system(let key, _) = aliasChord.key {
                XCTAssertEqual(key, expected, "Expected alias \(token) to map to \(expected).")
            } else {
                XCTFail("Expected system key for \(token).")
            }
        }
    }

    func testParsesCommandAndMacroAliases() throws {
        let spotlight = try KeyCodes.parseChord("spotlight")
        if case .keyboard(let keyCode, _) = spotlight.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_Space))
            XCTAssertEqual(spotlight.normalized, "cmd+space")
        } else {
            XCTFail("Expected spotlight macro to resolve to cmd+space.")
        }

        let raycast = try KeyCodes.parseChord("raycast")
        if case .keyboard(let keyCode, _) = raycast.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_Space))
            XCTAssertEqual(raycast.normalized, "cmd+space")
        } else {
            XCTFail("Expected raycast macro to resolve to cmd+space.")
        }

        let missionControl = try KeyCodes.parseChord("mission-control")
        if case .keyboard(let keyCode, _) = missionControl.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_F3))
            XCTAssertEqual(missionControl.normalized, "mission-control")
        } else {
            XCTFail("Expected mission-control macro to resolve to F3.")
        }
    }

    func testParsesSpaceSeparatedModifierChord() throws {
        let chord = try KeyCodes.parseChord("cmd space")
        if case .keyboard(let keyCode, _) = chord.key {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_Space))
            XCTAssertEqual(chord.normalized, "cmd+space")
        } else {
            XCTFail("Expected cmd space to parse to cmd+space.")
        }
    }

    func testParsesHoldTargetForModifierAndSystemTokens() throws {
        let shiftHold = try KeyCodes.parseHoldTarget("shift")
        if case .keyboard(let keyCode, let token) = shiftHold {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_Shift))
            XCTAssertEqual(token, "shift")
        } else {
            XCTFail("Expected shift as holdable keyboard key.")
        }

        let systemHold = try KeyCodes.parseHoldTarget("play")
        if case .system(let key, _) = systemHold {
            XCTAssertEqual(key, .playPause)
        } else {
            XCTFail("Expected system key for play hold target.")
        }

        let missionHold = try KeyCodes.parseHoldTarget("missioncontrol")
        if case .keyboard(let keyCode, _) = missionHold {
            XCTAssertEqual(keyCode, CGKeyCode(kVK_F3))
        } else {
            XCTFail("Expected hold target for missioncontrol.")
        }
    }

    func testRejectsModifierOnlyChord() {
        XCTAssertThrowsError(try KeyCodes.parseChord("cmd"))
    }

    func testRejectsUnsupportedToken() {
        XCTAssertThrowsError(try KeyCodes.parseChord("doesnotexist"))
    }

    func testRejectsSystemKeyWithModifier() {
        XCTAssertThrowsError(try KeyCodes.parseChord("shift+playpause"))
    }

    func testRejectsModifierOnlyHoldTargetForFn() {
        XCTAssertThrowsError(try KeyCodes.parseHoldTarget("fn"))
    }

    func testRejectsMalformedChordTokens() {
        XCTAssertThrowsError(try KeyCodes.parseChord(""))
        XCTAssertThrowsError(try KeyCodes.parseChord("  "))
        XCTAssertThrowsError(try KeyCodes.parseChord("ctrl++f1"))
    }
}
